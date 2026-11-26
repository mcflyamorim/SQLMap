# Combines evidence from all probes into one instance list per host.

function New-SQLMapInstance {
    param([string]$ComputerName, [string]$ServiceType, [string]$InstanceName)
    [ordered]@{
        ComputerName      = $ComputerName
        InstanceName      = $InstanceName
        ServiceType       = $ServiceType
        SqlInstance       = $null
        InstanceId        = $null
        Edition           = $null
        Version           = $null
        VersionSource     = $null   # SqlConnect | Registry | Prelogin | Browser (Browser = base release only, no CU)
        ProductName       = $null
        MajorVersion      = $null
        ProductLevel      = $null
        UpdateLevel       = $null
        UpdateReference   = $null
        ServicingBranch   = $null
        LatestUpdate      = $null
        LatestBuild       = $null
        LatestKB          = $null
        SecurityUpdateBuild = $null
        UpdatesBehind     = $null
        PatchStatus       = $null
        SupportStatus     = $null
        MainstreamEndDate = $null
        ExtendedEndDate   = $null
        Clustered         = $false
        ClusterName       = $null
        ClusterNodes      = @()
        TcpPort           = $null
        DynamicPort       = $null
        ServiceName       = $null
        ServiceState      = $null
        StartMode         = $null
        ServiceAccount    = $null
        AgentState        = $null
        IsRunning         = $null
        LastHeartbeatUtc  = $null
        Confidence        = $null
        Components        = New-Object System.Collections.Generic.List[string]
        SsisCatalog       = $null
        DetectedBy        = New-Object System.Collections.Generic.List[string]
        Notes             = New-Object System.Collections.Generic.List[string]
        SqlConnectStatus  = $null
        SqlConnectMessage = $null
        ServerName        = $null
        Collation         = $null
        IsHadrEnabled     = $null
        DatabaseCount     = $null
        DataSizeGB        = $null
        LogSizeGB         = $null
        MaxServerMemoryMB = $null
        CpuCount          = $null
        SqlStartTime      = $null
    }
}

function Add-SQLMapEvidence {
    param($Instance, [string]$Evidence)
    if (-not $Instance.DetectedBy.Contains($Evidence)) { $Instance.DetectedBy.Add($Evidence) }
}

function Add-SQLMapComponent {
    param($Instance, [string]$Component)
    if ($Component -and -not $Instance.Components.Contains($Component)) { $Instance.Components.Add($Component) }
}

# Secondary services shown as components of their engine / SSIS row
$script:ComponentServices = @{
    Agent              = @{ Parent = 'Engine'; Label = 'SQL Agent' }
    FullText           = @{ Parent = 'Engine'; Label = 'Full-Text' }
    Launchpad          = @{ Parent = 'Engine'; Label = 'ML Services' }
    PolyBase           = @{ Parent = 'Engine'; Label = 'PolyBase' }
    PolyBaseDMS        = @{ Parent = 'Engine'; Label = 'PolyBase' }
    SSISScaleOutMaster = @{ Parent = 'SSIS';   Label = 'Scale Out Master' }
    SSISScaleOutWorker = @{ Parent = 'SSIS';   Label = 'Scale Out Worker' }
}

function Merge-SQLMapInstance {
    param(
        [string]$ComputerName,
        [object[]]$Registry = @(),
        [object[]]$Services = @(),
        [object[]]$Browser = @(),
        [string[]]$SPN = @(),
        [string[]]$InstanceHint = @(),
        [int[]]$OpenSqlPorts = @(),
        [bool]$AuthoritativeOK
    )
    $map = [ordered]@{}
    $get = {
        param($type, $name)
        $k = "$type|$name".ToUpperInvariant()
        if (-not $map.Contains($k)) { $map[$k] = New-SQLMapInstance -ComputerName $ComputerName -ServiceType $type -InstanceName $name }
        $map[$k]
    }
    $find = {
        param($type, $name)
        $k = "$type|$name".ToUpperInvariant()
        if ($map.Contains($k)) { $map[$k] } else { $null }
    }

    # 1. Registry (installed instances)
    foreach ($r in $Registry) {
        $i = & $get $r.ServiceType $r.InstanceName
        Add-SQLMapEvidence $i 'Registry'
        $i.InstanceId       = $r.InstanceId
        $i.Edition          = $r.Edition
        $i.Version          = $r.Version
        if ($r.Version) { $i.VersionSource = 'Registry' }
        $i.Clustered        = [bool]$r.Clustered
        $i.ClusterName      = $r.ClusterName
        $i.ClusterNodes     = @($r.ClusterNodes)
        $i.TcpPort          = $r.TcpPort
        $i.DynamicPort      = $r.DynamicPort
        $i.LastHeartbeatUtc = $r.LastHeartbeatUtc
        foreach ($c in @($r.Components)) { Add-SQLMapComponent $i $c }
        if ($r.Wow64) { $i.Notes.Add('32-bit installation') }
    }

    # 2. Windows services
    foreach ($s in $Services) {
        if ($s.ServiceType -in 'Engine', 'SSAS', 'SSRS', 'PBIRS', 'SSIS') {
            $i = & $get $s.ServiceType $s.InstanceName
            Add-SQLMapEvidence $i 'Service'
            $i.ServiceName    = $s.Name
            $i.ServiceState   = $s.State
            $i.StartMode      = $s.StartMode
            $i.ServiceAccount = $s.StartName
        }
    }
    foreach ($s in $Services) {
        $cs = $script:ComponentServices[$s.ServiceType]
        if (-not $cs -or -not $s.InstanceName) { continue }
        $i = & $find $cs.Parent $s.InstanceName
        # Scale Out without the SSIS service of the same version still means SSIS is installed
        if (-not $i -and $cs.Parent -eq 'SSIS') { $i = & $get 'SSIS' $s.InstanceName; Add-SQLMapEvidence $i 'Service' }
        if (-not $i) { continue }
        Add-SQLMapComponent $i $cs.Label
        if ($s.ServiceType -eq 'Agent') { $i.AgentState = $s.State }
    }

    # 3. SQL Server Browser
    foreach ($b in $Browser) {
        $i = & $get 'Engine' $b.InstanceName
        Add-SQLMapEvidence $i 'Browser'
        if (-not $i.TcpPort -and $b.TcpPort) { $i.TcpPort = $b.TcpPort }
        # The Browser reports the base release (e.g. 15.0.2000.5) whatever CU is installed: good for the
        # product name, never for the patch level (see Complete-SQLMapInstance)
        if (-not $i.Version -and $b.Version) { $i.Version = $b.Version; $i.VersionSource = 'Browser' }
        if ($b.IsClustered) { $i.Clustered = $true }
    }

    # 4. SPNs and discovery hints (weak evidence: may be stale)
    foreach ($spn in $SPN) {
        # [regex]::Match, not -notmatch: in PS 5.1 -notmatch does not reliably fill $Matches
        $m = [regex]::Match([string]$spn, '^MSSQLSvc/[^:/]+(?::(.+))?$', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $suffix = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $null }
        $engines = @($map.Values | Where-Object { $_.ServiceType -eq 'Engine' })
        $target = $null
        if (-not $suffix) { $target = & $find 'Engine' 'MSSQLSERVER'; $suffix = 'MSSQLSERVER' }
        elseif ($suffix -match '^\d+$') {
            $target = $engines | Where-Object { $_.TcpPort -eq [int]$suffix } | Select-Object -First 1
            if (-not $target -and $suffix -eq '1433') { $target = & $find 'Engine' 'MSSQLSERVER' }
        }
        else { $target = & $find 'Engine' $suffix }

        if ($target) { Add-SQLMapEvidence $target 'SPN' }
        elseif (-not $AuthoritativeOK -and $suffix -notmatch '^\d+$') {
            $i = & $get 'Engine' $suffix
            Add-SQLMapEvidence $i 'SPN'
        }
    }
    foreach ($h in $InstanceHint) {
        if (-not $h) { continue }
        $i = & $find 'Engine' $h
        if (-not $i -and -not $AuthoritativeOK) { $i = & $get 'Engine' $h }
        if ($i) { Add-SQLMapEvidence $i 'Discovery' }
    }

    # 5. Open SQL TCP ports (the -TcpPort list plus ports named in the host's MSSQLSvc SPNs)
    foreach ($p in $OpenSqlPorts) {
        $engines = @($map.Values | Where-Object { $_.ServiceType -eq 'Engine' })
        $match = $engines | Where-Object { $_.TcpPort -eq $p } | Select-Object -First 1
        if (-not $match -and $p -eq 1433) {
            $match = $engines | Where-Object { $_.InstanceName -eq 'MSSQLSERVER' -and -not $_.TcpPort } | Select-Object -First 1
        }
        if (-not $match -and -not $AuthoritativeOK -and $p -ne 1433) {
            # 'MSSQLSvc/host:SQLEXPRESS' + 'MSSQLSvc/host:56615': with exactly one named instance still without a
            # port, the open SPN port is its port
            $portless = @($engines | Where-Object { -not $_.TcpPort -and $_.InstanceName -ne 'MSSQLSERVER' -and $_.InstanceName -notlike 'Unknown (TCP *' })
            if ($portless.Count -eq 1) { $match = $portless[0] }
        }
        if ($match) {
            Add-SQLMapEvidence $match 'TcpPort'
            if (-not $match.TcpPort) { $match.TcpPort = $p }
        }
        elseif (-not $AuthoritativeOK) {
            $name = if ($p -eq 1433) { 'MSSQLSERVER' } else { "Unknown (TCP $p)" }
            $i = & $get 'Engine' $name
            $i.TcpPort = $p
            Add-SQLMapEvidence $i 'TcpPort'
        }
    }

    @($map.Values)
}

function Complete-SQLMapInstance {
    # Derived fields: SqlInstance, running state, confidence, product/lifecycle.
    param($Instance, [datetime]$AsOf = (Get-Date))
    $i = $Instance
    $base = if ($i.Clustered -and $i.ClusterName) { $i.ClusterName } else { $i.ComputerName }
    # SSIS is not a connectable instance: show it as 'HOST (SSIS130)'
    if ($i.ServiceType -eq 'SSIS') { $i.SqlInstance = "$base ($($i.InstanceName))" }
    elseif ($i.InstanceName -eq 'MSSQLSERVER') { $i.SqlInstance = $base }
    elseif ($i.InstanceName -like 'Unknown (TCP *') { $i.SqlInstance = "$base,$($i.TcpPort)" }
    else { $i.SqlInstance = "$base\$($i.InstanceName)" }

    # SERVERPROPERTY('Edition') says '(64-bit)', the registry does not: keep one spelling
    if ($i.Edition) { $i.Edition = ([string]$i.Edition -replace '\s*\(64-bit\)\s*$', '').Trim() }

    if ($i.InstanceName -eq 'MICROSOFT##WID') {
        if (-not $i.Edition) { $i.Edition = 'Windows Internal Database' }
        $i.Notes.Add('Windows Internal Database (used by Windows roles, not a licensed SQL Server)')
    }

    # Running state: service state > SQL connection > registry heartbeat
    if ($i.ServiceState) { $i.IsRunning = ($i.ServiceState -eq 'Running') }
    elseif ($i.SqlConnectStatus -eq 'OK' -or $i.DetectedBy.Contains('Prelogin')) { $i.IsRunning = $true }
    elseif ($i.LastHeartbeatUtc) {
        $age = ([datetime]::UtcNow - [datetime]$i.LastHeartbeatUtc).TotalMinutes
        $i.IsRunning = ($age -le 10)
        $i.Notes.Add('Running state inferred from registry heartbeat')
    }

    $ev = $i.DetectedBy
    # Prelogin = a SQL Server answered the TDS handshake on that port
    if ($ev.Contains('Registry') -or $ev.Contains('Service') -or $ev.Contains('SqlConnect') -or $ev.Contains('Prelogin')) { $i.Confidence = 'High' }
    elseif ($ev.Contains('Browser') -or ($ev.Contains('SPN') -and $ev.Contains('TcpPort'))) { $i.Confidence = 'Medium' }
    else { $i.Confidence = 'Low' }

    # Registry PatchLevel -> ProductVersion format (13.3.7095.1 -> 13.0.7095.1, 10.53.x -> 10.50.x)
    if ($i.Version) { $i.Version = ConvertTo-SQLMapNormalizedVersion $i.Version }

    # Patch level vs. the latest update of the same servicing branch (CU or RTM-GDR).
    # SSRS/PBIRS have their own release track and are not in the reference.
    # A Browser version is the base release (no CU): comparing it would report patched servers as RTM.
    if ($i.VersionSource -eq 'Browser') {
        $i.PatchStatus = 'Unknown'
        $i.Notes.Add('Version reported by SQL Browser (base release, without CU): patch level unknown. The exact build comes from the registry, a SQL connection or the TDS handshake on the instance port.')
    }
    elseif ($i.Version -and $i.ServiceType -in 'Engine', 'SSAS', 'SSIS') {
        $bi = Get-SQLMapBuildInfo -Version $i.Version
        if (-not $i.UpdateLevel -and $bi.UpdateLevel) { $i.UpdateLevel = $bi.UpdateLevel }
        $i.ServicingBranch = $bi.ServicingBranch
        $i.LatestUpdate  = $bi.LatestUpdate
        $i.LatestBuild   = $bi.LatestBuild
        $i.LatestKB      = $bi.LatestKB
        $i.SecurityUpdateBuild = $bi.SecurityUpdateBuild
        $i.UpdatesBehind = $bi.UpdatesBehind
        $i.PatchStatus   = $bi.PatchStatus
    }

    $lookupVersion = $i.Version
    if (-not $lookupVersion -and $i.ServiceType -eq 'SSIS' -and $i.InstanceName -match '^SSIS(\d+)(\d)$') {
        # Service seen but registry unreadable: version folder 130 -> 13.0
        $lookupVersion = "$([int]$Matches[1]).$($Matches[2])"
    }
    $pi = Get-SQLMapProductInfo -Version $lookupVersion -ServiceType $i.ServiceType -AsOf $AsOf
    $i.MajorVersion      = $pi.MajorVersion
    $i.ProductName       = $pi.ProductName
    $i.SupportStatus     = $pi.SupportStatus
    $i.MainstreamEndDate = $pi.MainstreamEndDate
    $i.ExtendedEndDate   = $pi.ExtendedEndDate
    if ($i.LastHeartbeatUtc) { $i.LastHeartbeatUtc = ([datetime]$i.LastHeartbeatUtc).ToString('yyyy-MM-ddTHH:mm:ssZ') }

    # Convert lists to plain arrays so they serialize cleanly
    # .ToArray(): @() on generic lists can throw 'Argument types do not match' in PS 5.1
    $i.DetectedBy = $i.DetectedBy.ToArray()
    $i.Notes      = $i.Notes.ToArray()
    $i.Components = [string[]]@($i.Components.ToArray() | Sort-Object)
    [pscustomobject]$i
}
