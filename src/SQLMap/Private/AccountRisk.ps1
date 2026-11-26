# Service account review in Active Directory (read-only LDAP, readable by any domain user).
#
# For every account that runs a SQL Server service (or the host's computer account, when the service runs as a
# virtual / built-in account): type, privileged group membership (nested), adminCount, delegation, password
# age and policy, last logon, encryption types, SPNs, local admin on the scanned hosts, and sysadmin on the
# instances it runs (through its own login or a group login).
#
# Two layers: Get-SQLMapAdAccountData reads AD (raw data); Get-SQLMapAccountAssessment applies the rules to that
# data, so the rules can be tested without a domain.

# Privileged groups by well-known SID (names are localized) - domain RIDs and BUILTIN groups
$script:PrivilegedDomainRids = @{
    512 = 'Domain Admins'; 516 = 'Domain Controllers'; 518 = 'Schema Admins'; 519 = 'Enterprise Admins'
    520 = 'Group Policy Creator Owners'; 526 = 'Key Admins'; 527 = 'Enterprise Key Admins'
}
$script:PrivilegedBuiltinSids = @{
    'S-1-5-32-544' = 'Administrators'; 'S-1-5-32-548' = 'Account Operators'; 'S-1-5-32-549' = 'Server Operators'
    'S-1-5-32-550' = 'Print Operators'; 'S-1-5-32-551' = 'Backup Operators'
}
$script:PrivilegedGroupNames = @('DnsAdmins')   # no fixed SID
$script:SeverityOrder = @{ Critical = 4; High = 3; Medium = 2; Low = 1; None = 0 }

function ConvertTo-SQLMapSidString {
    param($Bytes)
    if (-not $Bytes) { return $null }
    try { (New-Object System.Security.Principal.SecurityIdentifier([byte[]]$Bytes, 0)).Value } catch { $null }
}

function Get-SQLMapPrivilegedGroupName {
    # Name of a privileged group from its SID (or name for DnsAdmins), $null otherwise
    param([string]$Sid, [string]$Name)
    if ($Sid -and $script:PrivilegedBuiltinSids.ContainsKey($Sid)) { return $script:PrivilegedBuiltinSids[$Sid] }
    $m = [regex]::Match([string]$Sid, '^S-1-5-21-\d+-\d+-\d+-(\d+)$')
    if ($m.Success -and $script:PrivilegedDomainRids.ContainsKey([int]$m.Groups[1].Value)) { return $script:PrivilegedDomainRids[[int]$m.Groups[1].Value] }
    if ($Name -and $Name -in $script:PrivilegedGroupNames) { return $Name }
    $null
}

function ConvertTo-SQLMapLdapFilterValue {
    # RFC 4515 escaping (DNs contain '\,' and may contain parentheses)
    param([string]$Value)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Value.ToCharArray()) {
        switch ($c) { '\' { [void]$sb.Append('\5c') } '*' { [void]$sb.Append('\2a') } '(' { [void]$sb.Append('\28') } ')' { [void]$sb.Append('\29') } "`0" { [void]$sb.Append('\00') } default { [void]$sb.Append($c) } }
    }
    $sb.ToString()
}

function Resolve-SQLMapServiceIdentity {
    # Who a service account is on the network:
    #   Domain  'CONTOSO\svc', 'svc@contoso.com', gMSA 'CONTOSO\gmsa$'  -> that AD account
    #   Virtual 'NT Service\MSSQL$X' and built-in LocalSystem / Network Service -> the host's computer account
    #   NoNetwork Local Service (anonymous on the network); Local '.\user' or 'HOST\user' -> not in AD
    param([string]$Account, [string]$ComputerName)
    $r = @{ Kind = 'Unknown'; Type = $null; Domain = $null; Sam = $null; Upn = $null; Display = $Account }
    if (-not $Account) { return $r }
    $a = $Account.Trim()
    if ($a -like 'Built-in account*') { $r.Kind = 'Computer'; $r.Type = 'Built-in account'; return $r }
    if ($a -match '^(NT AUTHORITY\\LOCAL ?SERVICE|LocalService)$') { $r.Kind = 'NoNetwork'; $r.Type = 'Local Service (built-in)'; return $r }
    if ($a -match '^NT SERVICE\\') { $r.Kind = 'Computer'; $r.Type = 'Virtual account'; return $r }
    if ($a -match '^(NT AUTHORITY\\|\.\\LocalSystem$|LocalSystem$|NetworkService$)') { $r.Kind = 'Computer'; $r.Type = 'Built-in account'; return $r }
    if ($a -match '^(.+?)\\(.+)$') {
        $d = $Matches[1]; $s = $Matches[2]
        if ($d -eq '.' -or ($ComputerName -and $d -ieq $ComputerName)) { $r.Kind = 'Local'; $r.Type = 'Local account'; return $r }
        $r.Kind = 'Domain'; $r.Domain = $d; $r.Sam = $s; return $r
    }
    if ($a -match '^(.+)@(.+)$') { $r.Kind = 'Domain'; $r.Upn = $a; $r.Sam = $Matches[1]; $r.Domain = $Matches[2]; return $r }
    $r.Kind = 'Domain'; $r.Sam = $a
    $r
}

function Get-SQLMapAdDomainInfo {
    # NetBIOS and DNS names of the scan's domain (to tell which accounts belong to it)
    param([string]$Domain, [pscredential]$Credential)
    $rootPath = if ($Domain) { "LDAP://$Domain/RootDSE" } else { 'LDAP://RootDSE' }
    $root = if ($Credential) { New-Object System.DirectoryServices.DirectoryEntry($rootPath, $Credential.UserName, $Credential.GetNetworkCredential().Password) }
            else { New-Object System.DirectoryServices.DirectoryEntry($rootPath) }
    $defaultNc = $null; $configNc = $null
    try {
        $defaultNc = [string]@($root.Properties['defaultNamingContext'])[0]
        $configNc = [string]@($root.Properties['configurationNamingContext'])[0]
    }
    catch { }
    if (-not $defaultNc) {
        throw 'this computer is not in a domain or cannot reach a domain controller (use -Domain and -Credential for another domain)'
    }
    $server = if ($Domain) { "$Domain/" } else { '' }
    $partPath = "LDAP://${server}CN=Partitions,$configNc"
    $part = if ($Credential) { New-Object System.DirectoryServices.DirectoryEntry($partPath, $Credential.UserName, $Credential.GetNetworkCredential().Password) }
            else { New-Object System.DirectoryServices.DirectoryEntry($partPath) }
    $s = New-Object System.DirectoryServices.DirectorySearcher($part)
    $s.Filter = "(&(objectClass=crossRef)(nCName=$(ConvertTo-SQLMapLdapFilterValue $defaultNc)))"
    foreach ($p in 'nETBIOSName', 'dnsRoot') { [void]$s.PropertiesToLoad.Add($p) }
    $x = $s.FindOne()
    @{
        DefaultNC = $defaultNc
        NetBios   = $(if ($x) { [string]$x.Properties['netbiosname'][0] } else { $null })
        Dns       = $(if ($x) { [string]$x.Properties['dnsroot'][0] } else { ($defaultNc -replace '^DC=', '' -replace ',DC=', '.') })
    }
}

function Get-SQLMapAdAccountData {
    # Raw AD data of one account (by sAMAccountName or UPN) with its nested groups; $null when not found
    param([string]$Sam, [string]$Upn, [string]$Domain, [pscredential]$Credential)
    $s = Get-SQLMapDirectorySearcher -Domain $Domain -Credential $Credential
    $s.Filter = if ($Upn) { "(|(userPrincipalName=$(ConvertTo-SQLMapLdapFilterValue $Upn))(sAMAccountName=$(ConvertTo-SQLMapLdapFilterValue $Sam)))" }
                else { "(sAMAccountName=$(ConvertTo-SQLMapLdapFilterValue $Sam))" }
    foreach ($p in 'distinguishedName', 'sAMAccountName', 'objectSid', 'objectClass', 'userAccountControl', 'adminCount',
                   'pwdLastSet', 'lastLogonTimestamp', 'msDS-SupportedEncryptionTypes', 'msDS-AllowedToDelegateTo',
                   'servicePrincipalName', 'primaryGroupID', 'msDS-PrincipalName') { [void]$s.PropertiesToLoad.Add($p) }
    $r = $s.FindOne()
    if (-not $r) { return $null }
    $p = $r.Properties
    $one = { param($n) $v = @($p[$n]); if ($v.Count) { $v[0] } else { $null } }
    $dn = [string](& $one 'distinguishedname')
    $sid = ConvertTo-SQLMapSidString (& $one 'objectsid')

    # Every group, nested included (LDAP_MATCHING_RULE_IN_CHAIN), plus the primary group (not in 'member')
    $groups = New-Object System.Collections.Generic.List[object]
    $g = Get-SQLMapDirectorySearcher -Domain $Domain -Credential $Credential
    $g.Filter = "(&(objectCategory=group)(member:1.2.840.113556.1.4.1941:=$(ConvertTo-SQLMapLdapFilterValue $dn)))"
    foreach ($q in 'sAMAccountName', 'objectSid') { [void]$g.PropertiesToLoad.Add($q) }
    $res = $g.FindAll()
    try { foreach ($x in $res) { $groups.Add([pscustomobject]@{ Name = [string]@($x.Properties['samaccountname'])[0]; SID = (ConvertTo-SQLMapSidString @($x.Properties['objectsid'])[0]) }) } }
    finally { $res.Dispose() }
    $pg = & $one 'primarygroupid'
    if ($pg -and $sid) {
        $pgSid = ($sid -replace '-\d+$', '') + "-$pg"
        if (-not ($groups | Where-Object { $_.SID -eq $pgSid })) {
            $pgName = if ($script:PrivilegedDomainRids.ContainsKey([int]$pg)) { $script:PrivilegedDomainRids[[int]$pg] } else { "Primary group (RID $pg)" }
            $groups.Add([pscustomobject]@{ Name = $pgName; SID = $pgSid })
        }
    }
    [pscustomobject]@{
        Sam                      = [string](& $one 'samaccountname')
        PrincipalName            = [string](& $one 'msds-principalname')
        DistinguishedName        = $dn
        SID                      = $sid
        ObjectClass              = @($p['objectclass'] | ForEach-Object { [string]$_ })
        UserAccountControl       = [int](& $one 'useraccountcontrol')
        AdminCount               = $(if ($null -ne (& $one 'admincount')) { [int](& $one 'admincount') } else { $null })
        PwdLastSet               = $(if ($null -ne (& $one 'pwdlastset')) { [int64](& $one 'pwdlastset') } else { $null })
        LastLogonTimestamp       = $(if ($null -ne (& $one 'lastlogontimestamp')) { [int64](& $one 'lastlogontimestamp') } else { $null })
        SupportedEncryptionTypes = $(if ($null -ne (& $one 'msds-supportedencryptiontypes')) { [int](& $one 'msds-supportedencryptiontypes') } else { $null })
        AllowedToDelegateTo      = @($p['msds-allowedtodelegateto'] | ForEach-Object { [string]$_ })
        SPNs                     = @($p['serviceprincipalname'] | ForEach-Object { [string]$_ })
        PrimaryGroupId           = $(if ($pg) { [int]$pg } else { $null })
        Groups                   = $groups.ToArray()
    }
}

function ConvertFrom-SQLMapFileTimeValue {
    param($Value)
    if ($null -eq $Value -or [int64]$Value -le 0 -or [int64]$Value -eq [int64]::MaxValue) { return $null }
    try { [datetime]::FromFileTimeUtc([int64]$Value) } catch { $null }
}

function Get-SQLMapAccountAssessment {
    # Applies the rules to raw AD data. LocalAdminHosts: @{ ComputerName; Members = @(@{ SID; Name }) } for every
    # host whose local Administrators group was read. OwnHosts: the SQL hosts this account serves.
    param($Data, [string]$Account, [string]$IdentityType, [object[]]$LocalAdminHosts = @(), [string[]]$OwnHosts = @(), [datetime]$AsOf = (Get-Date))
    $now = $AsOf.ToUniversalTime()
    $findings = New-Object System.Collections.Generic.List[object]
    $add = { param($sev, $tag, $text) $findings.Add([pscustomobject]@{ Severity = $sev; Tag = $tag; Text = $text }) }
    $uac = [int]$Data.UserAccountControl
    $classes = @($Data.ObjectClass)
    $isGmsa = $classes -contains 'msDS-GroupManagedServiceAccount'
    $isMsa = $classes -contains 'msDS-ManagedServiceAccount'
    $isComputer = (-not $isGmsa -and -not $isMsa -and $classes -contains 'computer')
    $isDc = ($uac -band 0x2000) -or $Data.PrimaryGroupId -eq 516 -or $Data.PrimaryGroupId -eq 521
    $type = if ($isGmsa) { 'gMSA' } elseif ($isMsa) { 'Managed service account' } elseif ($isComputer) { if ($IdentityType) { "Computer account ($IdentityType)" } else { 'Computer account' } } else { 'User account' }

    $disabled = [bool]($uac -band 0x2)
    $neverExpires = [bool]($uac -band 0x10000)
    $unconstrained = [bool]($uac -band 0x80000) -and -not $isDc
    $protocolTransition = [bool]($uac -band 0x1000000)
    $sensitive = [bool]($uac -band 0x100000)
    $noPreauth = [bool]($uac -band 0x400000)
    $pwdNotRequired = [bool]($uac -band 0x20)
    $pwdSet = ConvertFrom-SQLMapFileTimeValue $Data.PwdLastSet
    $pwdAge = if ($pwdSet) { [int][Math]::Floor(($now - $pwdSet).TotalDays) } else { $null }
    $lastLogon = ConvertFrom-SQLMapFileTimeValue $Data.LastLogonTimestamp
    $enc = $Data.SupportedEncryptionTypes
    $aes = ($null -ne $enc) -and (($enc -band 0x18) -ne 0)
    $encText = if ($null -eq $enc -or $enc -eq 0) { 'Not set (RC4 allowed)' }
               else { (@(@{ 1 = 'DES-CBC-CRC'; 2 = 'DES-CBC-MD5'; 4 = 'RC4'; 8 = 'AES128'; 16 = 'AES256' }.GetEnumerator() | Sort-Object Name | Where-Object { $enc -band $_.Name } | ForEach-Object { $_.Value })) -join ', ' }
    $spns = @($Data.SPNs | Where-Object { $_ })
    $kerberoastable = -not $isComputer -and -not $isGmsa -and -not $isMsa -and -not $disabled -and $spns.Count -gt 0

    # Groups: privileged ones by SID
    $privileged = @(foreach ($gr in @($Data.Groups)) { $n = Get-SQLMapPrivilegedGroupName -Sid $gr.SID -Name $gr.Name; if ($n -and -not ($isDc -and $n -eq 'Domain Controllers')) { $n } }) | Select-Object -Unique
    if ($privileged) { & $add 'Critical' 'Privileged group' ("Member of $($privileged -join ', ') (nested membership included). Whoever controls this SQL Server controls the domain.") }
    elseif ($Data.AdminCount -eq 1 -and -not $isDc) { & $add 'Medium' 'adminCount' 'adminCount = 1: the account is or was in a protected group; rights it kept (AdminSDHolder ACL) should be reviewed.' }
    if ($isDc) { & $add 'Critical' 'Domain controller' 'The SQL Server runs on a domain controller: its computer account is a domain controller account.' }

    # Delegation
    if ($unconstrained) { & $add 'Critical' 'Unconstrained delegation' 'Trusted for unconstrained delegation: anyone controlling the service can impersonate any user that connects to it, including domain admins.' }
    $delegateTo = @($Data.AllowedToDelegateTo | Where-Object { $_ })
    if ($delegateTo.Count) {
        if ($protocolTransition) { & $add 'High' 'Protocol transition' ("Constrained delegation with protocol transition (any user, no password needed) to: $($delegateTo -join ', ')") }
        else { & $add 'Medium' 'Constrained delegation' ("Constrained delegation to: $($delegateTo -join ', ')") }
    }
    elseif ($protocolTransition) { & $add 'Medium' 'Protocol transition' 'Trusted to authenticate for delegation (protocol transition) with no target list.' }

    # Kerberos ticket attacks
    if ($noPreauth) { & $add 'High' 'AS-REP roastable' 'Kerberos pre-authentication is disabled: anyone can request data to crack the password offline.' }
    if ($kerberoastable) {
        $weak = @()
        if ($null -ne $pwdAge -and $pwdAge -gt 365) { $weak += "password $pwdAge days old" }
        if (-not $aes) { $weak += 'RC4 allowed' }
        $sev = if ($weak.Count) { 'High' } else { 'Medium' }
        & $add $sev 'Kerberoastable' ("User account with SPNs: any domain user can request a service ticket and crack its password offline" + $(if ($weak.Count) { " ($($weak -join ', '))" } else { '' }) + '. A gMSA removes this risk.')
    }
    if ($pwdNotRequired) { & $add 'Medium' 'Password not required' 'PASSWD_NOTREQD is set: the account may have an empty password.' }
    if ($neverExpires -and -not $isComputer -and -not $isGmsa -and -not $isMsa) { & $add 'Low' 'Password never expires' ("Password never expires" + $(if ($null -ne $pwdAge) { "; last changed $pwdAge days ago" } else { '' }) + '.') }
    if ($disabled) { & $add 'Low' 'Disabled' 'The account is disabled in AD.' }

    # Local Administrators on the scanned hosts (direct member, or through one of its groups)
    $mySids = @(@($Data.SID) + @($Data.Groups | ForEach-Object { $_.SID }) | Where-Object { $_ })
    $adminOn = @(foreach ($lh in @($LocalAdminHosts)) {
        $via = @($lh.Members | Where-Object { $_.SID -and $mySids -contains $_.SID } | ForEach-Object { $_.Name })
        if ($via.Count) { [pscustomobject]@{ ComputerName = $lh.ComputerName; Via = ($via -join ', ') } }
    })
    $ownNames = @($OwnHosts | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $adminOther = @($adminOn | Where-Object { $ownNames -notcontains ([string]$_.ComputerName).ToUpperInvariant() })
    $adminOwn = @($adminOn | Where-Object { $ownNames -contains ([string]$_.ComputerName).ToUpperInvariant() })
    if ($adminOther.Count -and -not $isComputer) {
        & $add 'High' 'Local admin' ("Local administrator on $($adminOther.Count) other scanned host(s): $((@($adminOther | Select-Object -First 10 | ForEach-Object { $_.ComputerName })) -join ', ')" + $(if ($adminOther.Count -gt 10) { ', ...' } else { '' }) + '.')
    }
    elseif ($adminOther.Count -and $isComputer) {
        & $add 'High' 'Local admin' ("This computer account is local administrator on $($adminOther.Count) other scanned host(s): $((@($adminOther | Select-Object -First 10 | ForEach-Object { $_.ComputerName })) -join ', ').")
    }
    if ($adminOwn.Count -and -not $isComputer) { & $add 'Medium' 'Local admin on SQL host' 'Local administrator on its own SQL Server host; SQL Server services do not need it.' }

    $risk = 'None'
    foreach ($f in $findings) { if ($script:SeverityOrder[$f.Severity] -gt $script:SeverityOrder[$risk]) { $risk = $f.Severity } }
    $good = @()
    if ($isGmsa) { $good += 'gMSA: the password is long, random and rotated by AD' }
    if ($sensitive) { $good += 'Marked sensitive: cannot be delegated' }
    if ($aes -and $enc -and -not ($enc -band 0x4)) { $good += 'AES only' }

    [pscustomobject][ordered]@{
        Account                 = $Account
        Type                    = $type
        Checked                 = $true
        CheckNote               = $null
        Risk                    = $risk
        Tags                    = @($findings | Where-Object { $script:SeverityOrder[$_.Severity] -ge 2 } | ForEach-Object { $_.Tag } | Select-Object -Unique)
        Findings                = @($findings | Sort-Object { - $script:SeverityOrder[$_.Severity] } | ForEach-Object { "[$($_.Severity)] $($_.Tag): $($_.Text)" })
        GoodPractice            = $good
        Enabled                 = -not $disabled
        PrivilegedGroups        = @($privileged)
        AdminCount              = $Data.AdminCount
        Groups                  = @($Data.Groups | ForEach-Object { $_.Name } | Sort-Object -Unique)
        UnconstrainedDelegation = $unconstrained
        ConstrainedDelegationTo = $delegateTo
        ProtocolTransition      = $protocolTransition
        SensitiveNoDelegation   = $sensitive
        Kerberoastable          = $kerberoastable
        AsRepRoastable          = $noPreauth
        PasswordLastSet         = $(if ($pwdSet) { $pwdSet.ToString('yyyy-MM-dd') } else { $null })
        PasswordAgeDays         = $pwdAge
        PasswordNeverExpires    = $neverExpires
        LastLogon               = $(if ($lastLogon) { $lastLogon.ToString('yyyy-MM-dd') } else { $null })
        EncryptionTypes         = $encText
        SPNs                    = $spns
        LocalAdminOn            = @($adminOn | ForEach-Object { "$($_.ComputerName) (via $($_.Via))" })
        LocalAdminHostsChecked  = @($LocalAdminHosts).Count
        SID                     = $Data.SID
        GroupSids               = @($Data.Groups | ForEach-Object { $_.SID } | Where-Object { $_ })
        UsedBy                  = @()
    }
}

function New-SQLMapUncheckedAccount {
    param([string]$Account, [string]$Type, [string]$Note)
    [pscustomobject][ordered]@{
        Account = $Account; Type = $Type; Checked = $false; CheckNote = $Note; Risk = 'Not checked'; Tags = @(); Findings = @(); GoodPractice = @()
        Enabled = $null; PrivilegedGroups = @(); AdminCount = $null; Groups = @(); UnconstrainedDelegation = $null; ConstrainedDelegationTo = @()
        ProtocolTransition = $null; SensitiveNoDelegation = $null; Kerberoastable = $null; AsRepRoastable = $null; PasswordLastSet = $null
        PasswordAgeDays = $null; PasswordNeverExpires = $null; LastLogon = $null; EncryptionTypes = $null; SPNs = @(); LocalAdminOn = @()
        LocalAdminHostsChecked = 0; SID = $null; GroupSids = @(); UsedBy = @()
    }
}

function Invoke-SQLMapAccountReview {
    # After the scan: one AD pass over the unique service accounts of all instances.
    # Returns account objects; sets AccountRisk / AccountRiskSummary on the instances and resolves
    # 'sysadmin through a group' with the AD groups of each account.
    param([object[]]$Hosts, [object[]]$Instances, [string]$Domain, [pscredential]$Credential, [scriptblock]$Log)
    $entries = [ordered]@{}
    foreach ($i in @($Instances | Where-Object { $_ })) {
        foreach ($pair in @(@($i.ServiceAccount, 'service'), @($i.AgentServiceAccount, 'SQL Agent'))) {
            if (-not $pair[0]) { continue }
            $id = Resolve-SQLMapServiceIdentity -Account $pair[0] -ComputerName $i.ComputerName
            switch ($id.Kind) {
                'Domain'   { $key = ($(if ($id.Upn) { $id.Upn } else { "$($id.Domain)\$($id.Sam)" })).ToLowerInvariant(); $display = $pair[0]; $type = $null }
                'Computer' { $key = "computer:$($i.ComputerName)".ToLowerInvariant(); $display = "$($i.ComputerName)$ (computer account)"; $type = $id.Type }
                default    { $key = "other:$($pair[0])|$($i.ComputerName)".ToLowerInvariant(); $display = $pair[0]; $type = $id.Type }
            }
            if (-not $entries.Contains($key)) { $entries[$key] = @{ Identity = $id; Display = $display; Type = $type; ComputerName = $i.ComputerName; UsedBy = New-Object System.Collections.Generic.List[string]; Hosts = New-Object System.Collections.Generic.List[string]; Instances = New-Object System.Collections.Generic.List[object] } }
            $e = $entries[$key]
            $e.UsedBy.Add("$($i.SqlInstance) ($($pair[1]) as $($pair[0]))")
            if (-not $e.Hosts.Contains([string]$i.ComputerName)) { $e.Hosts.Add([string]$i.ComputerName) }
            if (-not $e.Instances.Contains($i)) { $e.Instances.Add($i) }
        }
    }
    if (-not $entries.Count) { return @() }

    $laHosts = @(foreach ($h in @($Hosts)) { if ($null -ne $h.LocalAdmins) { [pscustomobject]@{ ComputerName = $h.ComputerName; Members = @($h.LocalAdmins) } } })
    $dom = $null; $domError = $null
    if (@($entries.Values | Where-Object { $_.Identity.Kind -in 'Domain', 'Computer' }).Count) {
        try { $dom = Get-SQLMapAdDomainInfo -Domain $Domain -Credential $Credential }
        catch { $domError = Get-SQLMapErrorMessage $_; if ($Log) { & $Log "Service account review skipped: Active Directory not reachable ($domError)" 'Warning' } }
    }

    $accounts = foreach ($key in @($entries.Keys)) {
        $e = $entries[$key]; $id = $e.Identity
        $a = $null
        if ($id.Kind -eq 'Local') { $a = New-SQLMapUncheckedAccount $e.Display 'Local account' 'Local account of the SQL host: not in AD.' }
        elseif ($id.Kind -eq 'NoNetwork') { $a = New-SQLMapUncheckedAccount $e.Display $id.Type 'No network identity: nothing to check in AD.' }
        elseif ($id.Kind -notin 'Domain', 'Computer') { $a = New-SQLMapUncheckedAccount $e.Display 'Unknown' 'Account format not recognized.' }
        elseif (-not $dom) { $a = New-SQLMapUncheckedAccount $e.Display $(if ($id.Kind -eq 'Computer') { 'Computer account' } else { 'Domain account' }) "Active Directory not reachable: $domError" }
        else {
            $sam = if ($id.Kind -eq 'Computer') { "$($e.ComputerName)$" } else { $id.Sam }
            $sameDomain = ($id.Kind -eq 'Computer') -or (-not $id.Domain) -or ($id.Domain -ieq $dom.NetBios) -or ($id.Domain -ieq $dom.Dns)
            if (-not $sameDomain) { $a = New-SQLMapUncheckedAccount $e.Display 'Domain account' "Account of another domain ($($id.Domain)); the scan checks $($dom.NetBios)." }
            else {
                try {
                    $data = Get-SQLMapAdAccountData -Sam $sam -Upn $id.Upn -Domain $Domain -Credential $Credential
                    if (-not $data) { $a = New-SQLMapUncheckedAccount $e.Display 'Domain account' "Not found in $($dom.NetBios)." }
                    else { $a = Get-SQLMapAccountAssessment -Data $data -Account $e.Display -LocalAdminHosts $laHosts -OwnHosts $e.Hosts.ToArray() }
                }
                catch { $a = New-SQLMapUncheckedAccount $e.Display 'Domain account' "AD lookup failed: $(Get-SQLMapErrorMessage $_)" }
            }
        }
        $a.UsedBy = $e.UsedBy.ToArray()
        # Type of the service account per instance: virtual / built-in / local from the name; the AD type
        # (user account, gMSA, managed service account) for domain accounts
        foreach ($i in $e.Instances) {
            if ($i.ServiceAccount -and $e.UsedBy -contains "$($i.SqlInstance) (service as $($i.ServiceAccount))") {
                $i.ServiceAccountType = if ($id.Kind -eq 'Domain') { $a.Type } else { $id.Type }
            }
        }
        Complete-SQLMapInstanceAccount -Account $a -Instances $e.Instances.ToArray() -LocalAdminHosts $laHosts
        $a
    }
    @($accounts)
}

function Complete-SQLMapInstanceAccount {
    # Per instance: worst account risk, and sysadmin through a group login (AD groups x sysadmin group logins,
    # or BUILTIN\Administrators + local admin on the host)
    param($Account, [object[]]$Instances, [object[]]$LocalAdminHosts = @())
    $groupNames = @($Account.Groups | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($i in $Instances) {
        $cur = if ($i.AccountRisk) { [string]$i.AccountRisk } else { 'None' }
        $curOrder = if ($script:SeverityOrder.ContainsKey($cur)) { $script:SeverityOrder[$cur] } else { -1 }
        $newOrder = if ($script:SeverityOrder.ContainsKey($Account.Risk)) { $script:SeverityOrder[$Account.Risk] } else { -1 }
        if (-not $i.AccountRisk -or $newOrder -gt $curOrder) { $i.AccountRisk = $Account.Risk }
        if (@($Account.Tags).Count) { $i.AccountRiskSummary = (@(@($i.AccountRiskSummary -split ', ' | Where-Object { $_ }) + @($Account.Tags)) | Select-Object -Unique) -join ', ' }

        # Sysadmin through a Windows group login
        foreach ($role in 'Service', 'Agent') {
            $loginProp = "${role}AccountLogin"
            $acctProp = if ($role -eq 'Service') { 'ServiceAccount' } else { 'AgentServiceAccount' }
            if (-not $i.$acctProp -or $Account.UsedBy -notcontains "$($i.SqlInstance) ($(if ($role -eq 'Service') { 'service' } else { 'SQL Agent' }) as $($i.$acctProp))") { continue }
            if ([string]$i.$loginProp -like 'sysadmin*' -or -not $i.SysadminLogins) { continue }
            $viaGroups = @(foreach ($l in @($i.SysadminLogins)) {
                $n = ([string]$l -split '\\')[-1].ToLowerInvariant()
                if ($groupNames -contains $n) { $l }
            })
            $builtin = @($i.SysadminLogins | Where-Object { $_ -match '^BUILTIN\\' })
            $isLocalAdmin = @($Account.LocalAdminOn | Where-Object { $_ -like "$($i.ComputerName) (*" }).Count -gt 0
            if ($viaGroups.Count) { $i.$loginProp = "sysadmin (through group login $($viaGroups -join ', '))" }
            elseif ($builtin.Count -and $isLocalAdmin) { $i.$loginProp = "sysadmin (through BUILTIN\Administrators: local admin on the host)" }
        }
    }
}
