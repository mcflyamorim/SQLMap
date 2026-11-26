# CIM/WMI probe: opens a session (WSMan or DCOM), lists SQL-related services and collects host info.

function Connect-SQLMapCim {
    # Returns @{ Status; Protocol; Session; Message }. Session is $null for the local computer.
    param(
        [hashtable]$Context,
        [string]$ComputerName,
        [bool]$IsLocal,
        [int[]]$OpenPorts,
        [bool]$PortsKnown,
        [pscredential]$Credential,
        [int]$TimeoutSec = 15
    )
    $r = @{ Status = 'Unavailable'; Protocol = $null; Session = $null; Message = $null }
    if ($IsLocal) {
        $r.Status = 'OK'; $r.Protocol = 'Local'
        return $r
    }

    $protocols = @()
    if (-not $PortsKnown -or $OpenPorts -contains 5985) { $protocols += 'Wsman' }
    if (-not $PortsKnown -or $OpenPorts -contains 135)  { $protocols += 'Dcom' }
    if (-not $protocols) {
        $r.Message = 'TCP 5985 (WinRM) and 135 (RPC) closed'
        return $r
    }

    $errors = @()
    foreach ($proto in $protocols) {
        $session = $null
        try {
            $p = @{
                ComputerName        = $ComputerName
                SessionOption       = New-CimSessionOption -Protocol $proto
                OperationTimeoutSec = $TimeoutSec
                ErrorAction         = 'Stop'
            }
            if ($Credential) { $p.Credential = $Credential }
            $session = New-CimSession @p
            # Sessions connect lazily: run a cheap query to make sure it really works
            $null = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -Property Caption -ErrorAction Stop
            $r.Status = 'OK'; $r.Protocol = $proto.ToUpperInvariant(); $r.Session = $session; $r.Message = $null
            Add-SQLMapLog $Context "CIM session opened over $($r.Protocol)"
            return $r
        }
        catch {
            if ($session) { Remove-CimSession $session -ErrorAction SilentlyContinue }
            $kind = Get-SQLMapErrorKind $_
            $errors += "$($proto.ToUpperInvariant()): $(Get-SQLMapErrorMessage $_)"
            # Access denied on one protocol is the definitive answer; keep the strongest status
            if ($kind -eq 'AccessDenied' -or $r.Status -ne 'AccessDenied') { $r.Status = $kind }
            Add-SQLMapLog $Context "CIM over $proto failed: $(Get-SQLMapErrorMessage $_)" -Level Warning
        }
    }
    $r.Message = $errors -join ' | '
    $r
}

function Get-SQLMapServiceClass {
    # Maps a Windows service name to a SQL Server component + instance name.
    param([string]$Name)
    switch -Regex ($Name) {
        '^MSSQLSERVER$'                   { return @{ ServiceType = 'Engine';    InstanceName = 'MSSQLSERVER' } }
        '^MSSQL\$(.+)$'                   { return @{ ServiceType = 'Engine';    InstanceName = $Matches[1] } }
        '^SQLSERVERAGENT$'                { return @{ ServiceType = 'Agent';     InstanceName = 'MSSQLSERVER' } }
        '^SQLAgent\$(.+)$'                { return @{ ServiceType = 'Agent';     InstanceName = $Matches[1] } }
        '^MSSQLServerOLAPService$'        { return @{ ServiceType = 'SSAS';      InstanceName = 'MSSQLSERVER' } }
        '^MSOLAP\$(.+)$'                  { return @{ ServiceType = 'SSAS';      InstanceName = $Matches[1] } }
        '^ReportServer$'                  { return @{ ServiceType = 'SSRS';      InstanceName = 'MSSQLSERVER' } }
        '^ReportServer\$(.+)$'            { return @{ ServiceType = 'SSRS';      InstanceName = $Matches[1] } }
        '^SQLServerReportingServices$'    { return @{ ServiceType = 'SSRS';      InstanceName = 'SSRS' } }
        '^PowerBIReportServer$'           { return @{ ServiceType = 'PBIRS';     InstanceName = 'PBIRS' } }
        '^SQLBrowser$'                    { return @{ ServiceType = 'Browser';   InstanceName = $null } }
        # SSIS is one shared service per version: MsDtsServer (2005), MsDtsServer100 ... MsDtsServer170
        '^MsDtsServer(\d*)$'              { return @{ ServiceType = 'SSIS';      InstanceName = 'SSIS' + $(if ($Matches[1]) { $Matches[1] } else { '90' }) } }
        '^SSISScaleOutMaster(\d+)$'       { return @{ ServiceType = 'SSISScaleOutMaster'; InstanceName = 'SSIS' + $Matches[1] } }
        '^SSISScaleOutWorker(\d+)$'       { return @{ ServiceType = 'SSISScaleOutWorker'; InstanceName = 'SSIS' + $Matches[1] } }
        '^SQLPBENGINE(?:\$(.+))?$'        { return @{ ServiceType = 'PolyBase';  InstanceName = $(if ($Matches[1]) { $Matches[1] } else { 'MSSQLSERVER' }) } }
        '^SQLPBDMS(?:\$(.+))?$'           { return @{ ServiceType = 'PolyBaseDMS'; InstanceName = $(if ($Matches[1]) { $Matches[1] } else { 'MSSQLSERVER' }) } }
        '^MSSQLFDLauncher(?:\$(.+))?$'    { return @{ ServiceType = 'FullText';  InstanceName = $(if ($Matches[1]) { $Matches[1] } else { 'MSSQLSERVER' }) } }
        '^MSSQLLaunchpad(?:\$(.+))?$'     { return @{ ServiceType = 'Launchpad'; InstanceName = $(if ($Matches[1]) { $Matches[1] } else { 'MSSQLSERVER' }) } }
        '^(?:SQL|SSAS|SSIS)TELEMETRY\d*(?:\$(.+))?$' { return @{ ServiceType = 'Telemetry'; InstanceName = $Matches[1] } }
        '^SQLWriter$'                     { return @{ ServiceType = 'VSSWriter'; InstanceName = $null } }
    }
    $null
}

function Get-SQLMapCimService {
    param([hashtable]$Context, $CimSession)
    $filter = @(
        "Name LIKE 'MSSQL%'", "Name LIKE 'SQLAgent%'", "Name = 'SQLSERVERAGENT'", "Name LIKE 'MSOLAP%'",
        "Name LIKE 'ReportServer%'", "Name = 'SQLServerReportingServices'", "Name = 'PowerBIReportServer'",
        "Name = 'SQLBrowser'", "Name LIKE 'MsDtsServer%'", "Name LIKE 'SQLTELEMETRY%'", "Name LIKE 'SSASTELEMETRY%'",
        "Name LIKE 'SSISTELEMETRY%'", "Name = 'SQLWriter'", "Name LIKE 'SSISScaleOut%'", "Name LIKE 'SQLPBENGINE%'",
        "Name LIKE 'SQLPBDMS%'"
    ) -join ' OR '
    $p = @{
        ClassName   = 'Win32_Service'
        Filter      = $filter
        Property    = @('Name', 'DisplayName', 'State', 'StartMode', 'StartName', 'ProcessId')
        ErrorAction = 'Stop'
    }
    if ($CimSession) { $p.CimSession = $CimSession }
    foreach ($svc in (Get-CimInstance @p)) {
        $class = Get-SQLMapServiceClass $svc.Name
        if (-not $class) { continue }
        [pscustomobject][ordered]@{
            Name         = $svc.Name
            DisplayName  = $svc.DisplayName
            ServiceType  = $class.ServiceType
            InstanceName = $class.InstanceName
            State        = $svc.State
            StartMode    = $svc.StartMode
            StartName    = $svc.StartName
            ProcessId    = $svc.ProcessId
        }
    }
}

function Get-SQLMapCimHostInfo {
    # OS, hardware and virtualization info (cores matter for licensing).
    param([hashtable]$Context, $CimSession)
    $p = @{ ErrorAction = 'Stop' }
    if ($CimSession) { $p.CimSession = $CimSession }
    $info = [ordered]@{
        OSCaption = $null; OSVersion = $null; OSArchitecture = $null; LastBootTime = $null
        Domain = $null; Manufacturer = $null; Model = $null; IsVirtual = $null
        Sockets = $null; Cores = $null; LogicalProcessors = $null; MemoryGB = $null
    }
    try {
        $os = Get-CimInstance @p -ClassName Win32_OperatingSystem -Property Caption, Version, OSArchitecture, LastBootUpTime
        $info.OSCaption      = $os.Caption
        $info.OSVersion      = $os.Version
        $info.OSArchitecture = $os.OSArchitecture
        $info.LastBootTime   = ConvertTo-SQLMapIsoDate $os.LastBootUpTime
    } catch { Add-SQLMapLog $Context "Win32_OperatingSystem failed: $(Get-SQLMapErrorMessage $_)" -Level Warning }
    try {
        $cs = Get-CimInstance @p -ClassName Win32_ComputerSystem -Property Domain, Manufacturer, Model, NumberOfLogicalProcessors, TotalPhysicalMemory
        $info.Domain            = $cs.Domain
        $info.Manufacturer      = $cs.Manufacturer
        $info.Model             = $cs.Model
        $info.LogicalProcessors = $cs.NumberOfLogicalProcessors
        $info.MemoryGB          = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $info.IsVirtual         = [bool]("$($cs.Manufacturer) $($cs.Model)" -match 'Virtual|VMware|KVM|QEMU|Xen|HVM domU|Amazon EC2|Google Compute|OpenStack|Nutanix|Parallels|VirtualBox')
    } catch { Add-SQLMapLog $Context "Win32_ComputerSystem failed: $(Get-SQLMapErrorMessage $_)" -Level Warning }
    try {
        $cpu = @(Get-CimInstance @p -ClassName Win32_Processor -Property NumberOfCores)
        $info.Sockets = $cpu.Count
        $info.Cores   = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
    } catch { Add-SQLMapLog $Context "Win32_Processor failed: $(Get-SQLMapErrorMessage $_)" -Level Warning }
    [pscustomobject]$info
}
