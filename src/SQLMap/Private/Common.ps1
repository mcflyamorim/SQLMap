# Shared helpers: logging, error classification, name handling, product/lifecycle lookup.

function New-SQLMapContext {
    # Per-host scan context. Carries the log so every probe can append to it.
    param([string]$ComputerName)
    @{
        ComputerName = $ComputerName
        Log          = New-Object System.Collections.Generic.List[object]
    }
}

function Add-SQLMapLog {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $Context.Log.Add([pscustomobject][ordered]@{
        Time         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        Level        = $Level
        ComputerName = $Context.ComputerName
        Message      = $Message
    })
    Write-Verbose ("[{0}] {1}" -f $Context.ComputerName, $Message)
}

function Write-SQLMapLog {
    # Scan-level log: verbose stream + optional log file + optional UI state queue.
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$ComputerName = '',
        [string]$LogPath,
        [hashtable]$State
    )
    $time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = '[{0}] [{1}] {2}{3}' -f $time, $Level, $(if ($ComputerName) { "[$ComputerName] " } else { '' }), $Message
    switch ($Level) {
        'Warning' { Write-Warning $line }
        'Error'   { Write-Warning $line }
        default   { Write-Verbose $line }
    }
    if ($LogPath) {
        try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
    if ($State -and $State.ContainsKey('LogQueue') -and $State.LogQueue) {
        $State.LogQueue.Enqueue($line)
    }
}

function Get-SQLMapErrorKind {
    # Classifies an exception into a short, report-friendly status.
    param($ErrorObject)
    $ex = $ErrorObject
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    $messages = New-Object System.Collections.Generic.List[string]
    $cur = $ex
    while ($cur) {
        $messages.Add([string]$cur.Message)
        if ($cur -is [System.UnauthorizedAccessException] -or $cur -is [System.Security.SecurityException]) { return 'AccessDenied' }
        if ($cur.PSObject.Properties['NativeErrorCode'] -and [string]$cur.NativeErrorCode -eq 'AccessDenied') { return 'AccessDenied' }
        if ($cur.PSObject.Properties['HResult'] -and $cur.HResult -eq -2147024891) { return 'AccessDenied' }   # 0x80070005
        $cur = $cur.InnerException
    }
    $all = $messages -join ' | '
    # English + Portuguese Windows messages
    if ($all -match 'Access is denied|Acesso negado|0x80070005|Unauthorized|Login failed|Falha de logon') { return 'AccessDenied' }
    if ($all -match 'network path was not found|caminho de rede n|RPC server is unavailable|servidor RPC n|cannot connect|WinRM cannot complete|network-related or instance-specific') { return 'Unavailable' }
    if ($all -match 'timed out|timeout|tempo limite') { return 'Timeout' }
    return 'Error'
}

function Get-SQLMapErrorMessage {
    param($ErrorObject)
    $ex = $ErrorObject
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    while ($ex.InnerException -and ($ex -is [System.Management.Automation.MethodInvocationException] -or $ex -is [System.AggregateException])) {
        $ex = $ex.InnerException
    }
    ([string]$ex.Message).Trim()
}

function Get-SQLMapShortName {
    # 'srv01.contoso.com' -> 'srv01' ; IP addresses are returned unchanged.
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($Name, [ref]$ip)) { return $Name }
    ($Name -split '\.')[0]
}

function Test-SQLMapLocalComputer {
    param([string]$ComputerName)
    $n = $ComputerName.ToLowerInvariant()
    if ($n -in @('.', 'localhost')) { return $true }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($n, [ref]$ip)) {
        if ([System.Net.IPAddress]::IsLoopback($ip)) { return $true }
        # One of this machine's own addresses (e.g. inside a scanned IP range)
        if (-not $script:LocalIPs) {
            $script:LocalIPs = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                ForEach-Object { $_.GetIPProperties().UnicastAddresses } | ForEach-Object { $_.Address.ToString().ToLowerInvariant() })
        }
        return ($script:LocalIPs -contains $n)
    }
    $local = $env:COMPUTERNAME.ToLowerInvariant()
    if ((Get-SQLMapShortName $n) -eq $local) { return $true }
    try {
        $fqdn = [System.Net.Dns]::GetHostEntry('localhost').HostName.ToLowerInvariant()
        if ($n -eq $fqdn) { return $true }
    } catch { }
    return $false
}

function ConvertTo-SQLMapIsoDate {
    param($Date)
    if ($null -eq $Date) { return $null }
    try { ([datetime]$Date).ToString('yyyy-MM-ddTHH:mm:ss') } catch { $null }
}

function ConvertFrom-SQLMapFileTime {
    # SQL Server writes uptime_time_utc as an 8-byte little-endian FILETIME.
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 8) { return $null }
    try { [datetime]::FromFileTimeUtc([BitConverter]::ToInt64($Bytes, 0)) } catch { $null }
}

function Get-SQLMapProductInfo {
    # Maps a build number (e.g. 15.0.4415.2) to product name and lifecycle status.
    param(
        [string]$Version,
        [string]$ServiceType = 'Engine',
        [datetime]$AsOf = (Get-Date)
    )
    $info = [ordered]@{
        MajorVersion      = $null
        ProductName       = $null
        MainstreamEndDate = $null
        ExtendedEndDate   = $null
        SupportStatus     = 'Unknown'
    }
    if ($ServiceType -eq 'PBIRS') {
        $info.ProductName   = 'Power BI Report Server'
        $info.SupportStatus = 'Modern lifecycle'
        return $info
    }
    if ([string]::IsNullOrWhiteSpace($Version)) { return $info }

    $parts = $Version.Trim() -split '\.'
    $major = 0; $minor = 0
    if (-not [int]::TryParse($parts[0], [ref]$major)) { return $info }
    if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1], [ref]$minor) }
    $info.MajorVersion = $major

    $catalog = $script:SqlProducts.products
    $product = $catalog | Where-Object { $_.major -eq $major -and $_.minor -eq $minor } | Select-Object -First 1
    if (-not $product) { $product = $catalog | Where-Object { $_.major -eq $major } | Select-Object -First 1 }
    if (-not $product) {
        $info.ProductName = "Unknown (v$major)"
        return $info
    }

    $info.ProductName       = $product.name
    $info.MainstreamEndDate = $product.mainstreamEnd
    $info.ExtendedEndDate   = $product.extendedEnd

    if ($product.extendedEnd -and $AsOf.Date -gt [datetime]$product.extendedEnd) {
        $info.SupportStatus = 'Out of support'
    }
    elseif ($product.mainstreamEnd -and $AsOf.Date -gt [datetime]$product.mainstreamEnd) {
        $info.SupportStatus = 'Extended support'
    }
    elseif ($product.mainstreamEnd) {
        $info.SupportStatus = 'Mainstream support'
    }
    else {
        $info.SupportStatus = 'Supported (dates not set)'
    }
    return $info
}

function Get-SQLMapMachineSid {
    # The machine SID: the SID of one of its local accounts ('HOST\Administrator') without the RID.
    # Unique per Windows installation (unless cloned without sysprep).
    param([object[]]$LocalAdmins, [string]$ComputerName)
    if (-not $ComputerName) { return $null }
    foreach ($m in @($LocalAdmins)) {
        if (-not $m -or -not $m.SID) { continue }
        $parts = ([string]$m.Name) -split '\\'
        $sm = [regex]::Match([string]$m.SID, '^(S-1-5-21-\d+-\d+-\d+)-\d+$')
        if ($parts.Count -eq 2 -and $parts[0] -ieq $ComputerName -and $sm.Success) { return $sm.Groups[1].Value }
    }
    $null
}

function Get-SQLMapHostIdentityKey {
    # Keys that identify a machine whatever name or address reached it: its real computer name plus its
    # MachineGuid or machine SID. Requiring the name keeps VM clones made without sysprep (same GUID and SID,
    # different names) apart. Works with scans saved before these fields existed (SQL server name, local admins).
    param($HostResult)
    $h = $HostResult
    $name = [string]$h.ActualComputerName
    if (-not $name) {
        $name = @(@($h.Instances) | Where-Object { $_ -and $_.ServiceType -eq 'Engine' -and $_.ServerName -and -not $_.Clustered } |
                  ForEach-Object { ([string]$_.ServerName -split '\\')[0] }) | Select-Object -First 1
    }
    if (-not $name) { return @() }
    $name = $name.ToUpperInvariant()
    $sid = [string]$h.MachineSid
    if (-not $sid) { $sid = Get-SQLMapMachineSid -LocalAdmins $h.LocalAdmins -ComputerName $name }
    $keys = @()
    if ($h.MachineGuid) { $keys += "guid|$name|$(([string]$h.MachineGuid).ToLowerInvariant())" }
    if ($sid) { $keys += "sid|$name|$sid" }
    $keys
}

function Get-SQLMapInstanceTypeText {
    # Per-type breakdown of a host's instances: 'Engine 1, SSRS 1' (empty when there are none)
    param([object[]]$Instances)
    $counts = [ordered]@{}
    foreach ($t in 'Engine', 'SSAS', 'SSRS', 'PBIRS', 'SSIS') { $counts[$t] = 0 }
    foreach ($i in @($Instances)) {
        if (-not $i -or -not $i.ServiceType) { continue }
        if (-not $counts.Contains([string]$i.ServiceType)) { $counts[[string]$i.ServiceType] = 0 }
        $counts[[string]$i.ServiceType]++
    }
    (@($counts.Keys | Where-Object { $counts[$_] -gt 0 } | ForEach-Object { "$_ $($counts[$_])" })) -join ', '
}

function Join-SQLMapList {
    # Flattens arrays for CSV output.
    param($Value, [string]$Separator = '; ')
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value) | Where-Object { $null -ne $_ -and "$_" -ne '' }) -join $Separator }
    return [string]$Value
}
