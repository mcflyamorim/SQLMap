# Discovery: builds the list of computers to scan.
# Every function returns "target" objects created by New-SQLMapTarget.

function New-SQLMapTarget {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Source,
        [string]$IPAddress,
        [string]$OperatingSystem,
        [string]$Description,
        [string[]]$SPN = @(),
        [string[]]$InstanceHint = @(),
        # @{ SPN; Account; Kind = User|ManagedServiceAccount|Computer; Duplicate } from SPN discovery
        [object[]]$SpnOwner = @()
    )
    [pscustomobject][ordered]@{
        ComputerName    = $ComputerName.Trim()
        # Upper case like the rest (AD can return 'srv-fs01'); IP addresses are unaffected
        ShortName       = (Get-SQLMapShortName $ComputerName.Trim()).ToUpperInvariant()
        Sources         = @($Source)
        IPAddress       = $IPAddress
        OperatingSystem = $OperatingSystem
        Description     = $Description
        SPNs            = @($SPN)
        InstanceHints   = @($InstanceHint)
        SpnOwners       = @($SpnOwner | Where-Object { $_ })
    }
}

function Merge-SQLMapTarget {
    # De-duplicates targets by short name (or IP), merging sources/SPNs/hints.
    param([object[]]$Target)
    $map = [ordered]@{}
    foreach ($t in $Target) {
        if (-not $t) { continue }
        $key = $t.ShortName.ToLowerInvariant()
        if (-not $map.Contains($key)) {
            $map[$key] = $t
            continue
        }
        $e = $map[$key]
        $e.Sources       = @($e.Sources + $t.Sources | Select-Object -Unique)
        $e.SPNs          = @($e.SPNs + $t.SPNs | Where-Object { $_ } | Select-Object -Unique)
        $e.InstanceHints = @($e.InstanceHints + $t.InstanceHints | Where-Object { $_ } | Select-Object -Unique)
        $known = @($e.SpnOwners | ForEach-Object { "$($_.SPN)|$($_.Account)".ToLowerInvariant() })
        $e.SpnOwners     = @(@($e.SpnOwners) + @($t.SpnOwners | Where-Object { $_ -and ("$($_.SPN)|$($_.Account)".ToLowerInvariant() -notin $known) }) | Where-Object { $_ })
        if (-not $e.IPAddress -and $t.IPAddress) { $e.IPAddress = $t.IPAddress }
        if (-not $e.OperatingSystem -and $t.OperatingSystem) { $e.OperatingSystem = $t.OperatingSystem }
        if (-not $e.Description -and $t.Description) { $e.Description = $t.Description }
        # Prefer the FQDN form when we have one
        if ($e.ComputerName -notmatch '\.' -and $t.ComputerName -match '\.' -and -not ($t.ComputerName -match '^\d+\.\d+\.\d+\.\d+$')) {
            $e.ComputerName = $t.ComputerName
        }
    }
    @($map.Values)
}

function ConvertTo-SQLMapComputerName {
    # Accepts 'srv', 'srv\inst', 'srv,1433', 'tcp:srv,1433' and returns 'srv'.
    param([string]$Value)
    $v = $Value.Trim()
    $v = $v -replace '^(tcp|np|lpc):', ''
    $v = ($v -split '[\\,]')[0]
    $v.Trim()
}

function Get-SQLMapDirectorySearcher {
    param([string]$Domain, [string]$SearchBase, [pscredential]$Credential)
    $path = $null
    if ($SearchBase) { $path = "LDAP://$SearchBase" }
    elseif ($Domain) { $path = "LDAP://$Domain" }

    $entry = $null
    if ($Credential) {
        if (-not $path) {
            $path = 'LDAP://' + [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
        }
        $entry = New-Object System.DirectoryServices.DirectoryEntry($path, $Credential.UserName, $Credential.GetNetworkCredential().Password)
    }
    elseif ($path) {
        $entry = New-Object System.DirectoryServices.DirectoryEntry($path)
    }

    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    if ($entry) { $searcher.SearchRoot = $entry }
    $searcher.PageSize = 1000
    $searcher
}

function ConvertTo-SQLMapLdapValue {
    # Escapes LDAP filter special characters but keeps '*' as a wildcard.
    param([string]$Value)
    $Value -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00'
}

function Get-SQLMapAdComputerTarget {
    param(
        [string]$Domain,
        [string]$SearchBase,
        [string]$NameFilter = '*',
        [switch]$IncludeWorkstations,
        [int]$ActiveWithinDays = 90,
        [pscredential]$Credential
    )
    $searcher = Get-SQLMapDirectorySearcher -Domain $Domain -SearchBase $SearchBase -Credential $Credential
    $name = ConvertTo-SQLMapLdapValue $NameFilter
    $osFilter = if ($IncludeWorkstations) { '' } else { '(operatingSystem=*server*)' }
    # enabled computer accounts only (ACCOUNTDISABLE bit = 2)
    $searcher.Filter = "(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(name=$name)$osFilter)"
    foreach ($p in 'name', 'dnshostname', 'operatingsystem', 'description', 'lastlogontimestamp') { [void]$searcher.PropertiesToLoad.Add($p) }

    $cutoff = if ($ActiveWithinDays -gt 0) { (Get-Date).AddDays(-$ActiveWithinDays) } else { $null }
    $results = $searcher.FindAll()
    try {
        foreach ($r in $results) {
            $p = $r.Properties
            $desc = if ($p['description'].Count) { [string]$p['description'][0] } else { $null }
            # Failover cluster virtual network names are reported through their nodes
            if ($desc -like 'Failover cluster virtual network*') { continue }
            if ($cutoff -and $p['lastlogontimestamp'].Count) {
                $last = [datetime]::FromFileTime([int64]$p['lastlogontimestamp'][0])
                if ($last -lt $cutoff) { continue }
            }
            $cn = if ($p['dnshostname'].Count) { [string]$p['dnshostname'][0] } else { [string]$p['name'][0] }
            $os = if ($p['operatingsystem'].Count) { [string]$p['operatingsystem'][0] } else { $null }
            New-SQLMapTarget -ComputerName $cn -Source 'ActiveDirectory' -OperatingSystem $os -Description $desc
        }
    }
    finally { $results.Dispose() }
}

function Get-SQLMapSpnTarget {
    # Finds every MSSQLSvc SPN in the domain (computer and service accounts).
    param([string]$Domain, [string]$SearchBase, [pscredential]$Credential)
    $searcher = Get-SQLMapDirectorySearcher -Domain $Domain -SearchBase $SearchBase -Credential $Credential
    $searcher.Filter = '(servicePrincipalName=MSSQLSvc/*)'
    # The account holding an SPN is the SQL Server service account when it is a user or managed service account
    # (readable by any domain user, no admin rights on the SQL Server host needed)
    foreach ($p in 'serviceprincipalname', 'samaccountname', 'objectclass', 'msds-principalname') { [void]$searcher.PropertiesToLoad.Add($p) }

    $byHost = @{}
    $spnAccounts = @{}   # SPN (lower case) -> accounts holding it; more than one = duplicate SPN
    $results = $searcher.FindAll()
    try {
        foreach ($r in $results) {
            $classes = @($r.Properties['objectclass'] | ForEach-Object { [string]$_ })
            $kind = if ($classes -contains 'msDS-GroupManagedServiceAccount' -or $classes -contains 'msDS-ManagedServiceAccount') { 'ManagedServiceAccount' }
                    elseif ($classes -contains 'computer') { 'Computer' } else { 'User' }
            $principal = @($r.Properties['msds-principalname'])[0]
            $account = if ($principal) { [string]$principal } else { [string]@($r.Properties['samaccountname'])[0] }
            foreach ($spn in $r.Properties['serviceprincipalname']) {
                # [regex]::Match, not -notmatch: in PS 5.1 -notmatch does not reliably fill $Matches
                $m = [regex]::Match([string]$spn, '^MSSQLSvc/([^:/]+)(?::(.+))?$', 'IgnoreCase')
                if (-not $m.Success) { continue }
                $h = $m.Groups[1].Value
                $suffix = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $null }
                $key = (Get-SQLMapShortName $h).ToLowerInvariant()
                if (-not $byHost.ContainsKey($key)) { $byHost[$key] = @{ Name = $h; SPNs = @(); Hints = @(); Owners = @() } }
                $byHost[$key].SPNs += [string]$spn
                if ($suffix -and $suffix -notmatch '^\d+$') { $byHost[$key].Hints += $suffix }
                $owner = [pscustomobject]@{ SPN = [string]$spn; Account = $account; Kind = $kind; Duplicate = $false }
                $byHost[$key].Owners += $owner
                $spnKey = ([string]$spn).ToLowerInvariant()
                if (-not $spnAccounts.ContainsKey($spnKey)) { $spnAccounts[$spnKey] = @() }
                $spnAccounts[$spnKey] += $account
            }
        }
    }
    finally { $results.Dispose() }

    foreach ($k in $byHost.Keys) {
        $e = $byHost[$k]
        foreach ($o in $e.Owners) { $o.Duplicate = (@($spnAccounts[$o.SPN.ToLowerInvariant()] | Select-Object -Unique).Count -gt 1) }
        New-SQLMapTarget -ComputerName $e.Name -Source 'SPN' -SPN ($e.SPNs | Select-Object -Unique) -InstanceHint ($e.Hints | Select-Object -Unique) -SpnOwner $e.Owners
    }
}

function ConvertTo-SQLMapUInt32 {
    param([System.Net.IPAddress]$IP)
    $b = $IP.GetAddressBytes()
    [Array]::Reverse($b)
    [BitConverter]::ToUInt32($b, 0)
}

function ConvertFrom-SQLMapUInt32 {
    param([uint32]$Value)
    $b = [BitConverter]::GetBytes($Value)
    [Array]::Reverse($b)
    (New-Object System.Net.IPAddress (, $b)).ToString()
}

function Get-SQLMapIpRangeTarget {
    # Accepts '10.0.0.0/24', '10.0.0.10-10.0.0.50', '10.0.0.10-50' or a single IP.
    param([string[]]$Range, [int]$MaxAddresses = 65536)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Range) {
        $r = $r.Trim()
        if (-not $r) { continue }
        $first = $null; $last = $null
        if ($r -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
            $prefix = [int]$Matches[2]
            if ($prefix -lt 8 -or $prefix -gt 32) { throw "Invalid CIDR prefix in '$r' (allowed: /8 to /32)." }
            $base = ConvertTo-SQLMapUInt32 ([System.Net.IPAddress]::Parse($Matches[1]))
            # Note: 0xFFFFFFFF is Int32 -1 in PowerShell, so use the decimal literal with uint64 math
            $all = [uint64]4294967295
            $mask = [uint64](($all -shl (32 - $prefix)) -band $all)
            $network = [uint64]$base -band $mask
            $broadcast = $network + ($all - $mask)
            if ($prefix -ge 31) { $first = $network; $last = $broadcast }
            else { $first = $network + 1; $last = $broadcast - 1 }
        }
        elseif ($r -match '^(\d{1,3}(?:\.\d{1,3}){3})-(\d{1,3}(?:\.\d{1,3}){3})$') {
            $first = ConvertTo-SQLMapUInt32 ([System.Net.IPAddress]::Parse($Matches[1]))
            $last  = ConvertTo-SQLMapUInt32 ([System.Net.IPAddress]::Parse($Matches[2]))
        }
        elseif ($r -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.)(\d{1,3})-(\d{1,3})$') {
            $first = ConvertTo-SQLMapUInt32 ([System.Net.IPAddress]::Parse($Matches[1] + $Matches[2]))
            $last  = ConvertTo-SQLMapUInt32 ([System.Net.IPAddress]::Parse($Matches[1] + $Matches[3]))
        }
        elseif ($r -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
            $first = ConvertTo-SQLMapUInt32 ([System.Net.IPAddress]::Parse($r)); $last = $first
        }
        else { throw "Invalid IP range '$r'. Use CIDR (10.0.0.0/24), a range (10.0.0.1-10.0.0.50) or a single IP." }

        if ($last -lt $first) { throw "Invalid IP range '$r': end address is lower than start address." }
        if (($list.Count + ($last - $first + 1)) -gt $MaxAddresses) {
            throw "IP range(s) exceed $MaxAddresses addresses. Narrow the range or raise -MaxAddresses."
        }
        for ($i = [uint64]$first; $i -le $last; $i++) { $list.Add((ConvertFrom-SQLMapUInt32 ([uint32]$i))) }
    }
    foreach ($ip in $list) { New-SQLMapTarget -ComputerName $ip -Source 'IPRange' -IPAddress $ip }
}

function ConvertFrom-SQLMapBrowserResponse {
    # Parses an SSRP response: 0x05, 2-byte length, then 'ServerName;X;InstanceName;Y;...;;' records.
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 4 -or $Bytes[0] -ne 0x05) { return @() }
    $text = [System.Text.Encoding]::ASCII.GetString($Bytes, 3, $Bytes.Length - 3)
    foreach ($record in ($text -split ';;')) {
        if ([string]::IsNullOrWhiteSpace($record)) { continue }
        $tokens = $record.Split(';')
        $h = @{}
        for ($i = 0; $i + 1 -lt $tokens.Count; $i += 2) { $h[$tokens[$i]] = $tokens[$i + 1] }
        if (-not $h.ContainsKey('InstanceName')) { continue }
        $port = $null
        if ($h.ContainsKey('tcp')) { $tmp = 0; if ([int]::TryParse($h['tcp'], [ref]$tmp)) { $port = $tmp } }
        [pscustomobject][ordered]@{
            ServerName   = $h['ServerName']
            InstanceName = $h['InstanceName']
            IsClustered  = ($h['IsClustered'] -eq 'Yes')
            Version      = $h['Version']
            TcpPort      = $port
            NamedPipe    = $h['np']
        }
    }
}

function Get-SQLMapBroadcastTarget {
    # Same UDP broadcast SSMS uses ("Browse for servers"). Only reaches the local subnet.
    param([int]$TimeoutMs = 3000)
    $udp = New-Object System.Net.Sockets.UdpClient
    $found = @{}
    try {
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 500
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 1434)
        [void]$udp.Send([byte[]](0x02), 1, $ep)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $bytes = $udp.Receive([ref]$remote)
                $ip = $remote.Address.ToString()
                foreach ($inst in (ConvertFrom-SQLMapBrowserResponse $bytes)) {
                    $name = if ($inst.ServerName) { $inst.ServerName } else { $ip }
                    $key = $name.ToLowerInvariant()
                    if (-not $found.ContainsKey($key)) { $found[$key] = @{ Name = $name; IP = $ip; Hints = @() } }
                    $found[$key].Hints += $inst.InstanceName
                }
            }
            catch [System.Net.Sockets.SocketException] { }   # receive timeout, keep listening until deadline
        }
    }
    finally { $udp.Close() }
    foreach ($k in $found.Keys) {
        $e = $found[$k]
        New-SQLMapTarget -ComputerName $e.Name -Source 'Broadcast' -IPAddress $e.IP -InstanceHint ($e.Hints | Select-Object -Unique)
    }
}

function Get-SQLMapFileTarget {
    # .txt: one computer per line (# comments allowed). .csv: column ComputerName/Name/Server/Host/SqlInstance.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Input file '$Path' not found." }
    $names = @()
    if ([IO.Path]::GetExtension($Path) -eq '.csv') {
        $rows = Import-Csv -LiteralPath $Path
        if ($rows) {
            $col = @('ComputerName', 'Name', 'Server', 'Host', 'SqlInstance', 'Instance') |
                Where-Object { $rows[0].PSObject.Properties.Name -contains $_ } | Select-Object -First 1
            if (-not $col) { throw "CSV '$Path' needs one of the columns: ComputerName, Name, Server, Host, SqlInstance." }
            $names = $rows | ForEach-Object { $_.$col }
        }
    }
    else {
        $names = Get-Content -LiteralPath $Path | ForEach-Object { ($_ -split '#')[0].Trim() }
    }
    foreach ($n in $names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        New-SQLMapTarget -ComputerName (ConvertTo-SQLMapComputerName $n) -Source 'File'
    }
}
