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

# Local group members through the Net API (what 'net localgroup' uses): one RPC call that returns each member's SID
# and name. WMI's Win32_GroupUser resolves every member against the domain on domain-joined servers and can take
# minutes, so it is only the fallback.
$script:LocalGroupApi = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
namespace SQLMap {
    public static class LocalGroupApi {
        [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
        static extern int NetLocalGroupGetMembers(string server, string group, int level, out IntPtr buf, int prefMax, out int read, out int total, IntPtr resume);
        [DllImport("netapi32.dll")] static extern int NetApiBufferFree(IntPtr buf);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool LookupAccountSid(string system, byte[] sid, StringBuilder name, ref int nameLen, StringBuilder domain, ref int domainLen, out int use);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct LOCALGROUP_MEMBERS_INFO_2 { public IntPtr Sid; public int SidUsage; public string DomainAndName; }

        // Name of a well-known group on that computer (localized, e.g. 'Administradores' for S-1-5-32-544)
        public static string GroupName(string server, string sid) {
            SecurityIdentifier s = new SecurityIdentifier(sid);
            byte[] b = new byte[s.BinaryLength]; s.GetBinaryForm(b, 0);
            StringBuilder name = new StringBuilder(256), dom = new StringBuilder(256);
            int nl = 256, dl = 256, use;
            if (!LookupAccountSid(server, b, name, ref nl, dom, ref dl, out use)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return name.ToString();
        }

        // Members: { SID, DOMAIN\name, SID_NAME_USE }
        public static string[][] Members(string server, string group) {
            IntPtr buf; int read, total;
            int rc = NetLocalGroupGetMembers(server, group, 2, out buf, -1, out read, out total, IntPtr.Zero);
            if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);
            try {
                List<string[]> list = new List<string[]>();
                int size = Marshal.SizeOf(typeof(LOCALGROUP_MEMBERS_INFO_2));
                for (int i = 0; i < read; i++) {
                    LOCALGROUP_MEMBERS_INFO_2 m = (LOCALGROUP_MEMBERS_INFO_2)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + (long)i * size), typeof(LOCALGROUP_MEMBERS_INFO_2));
                    list.Add(new string[] { new SecurityIdentifier(m.Sid).Value, m.DomainAndName, m.SidUsage.ToString() });
                }
                return list.ToArray();
            }
            finally { NetApiBufferFree(buf); }
        }
    }
}
'@

function Get-SQLMapLocalAdmin {
    # Members of the local Administrators group, found by its well-known SID (the name is localized, e.g.
    # 'Administradores'). Each member: @{ Name = 'DOMAIN\x'; SID; Kind = User | Group | System }
    # Net API first (fast, current Windows identity); WMI only as a fallback (slow on domain members, and the
    # only way when -Credential differs from the current user).
    param([hashtable]$Context, [string]$ComputerName, [bool]$IsLocal, $CimSession)
    if (-not ('SQLMap.LocalGroupApi' -as [type])) { Add-Type -TypeDefinition $script:LocalGroupApi -ErrorAction Stop }
    $server = if ($IsLocal) { $null } else { $ComputerName }
    try {
        $groupName = [SQLMap.LocalGroupApi]::GroupName($server, 'S-1-5-32-544')
        $rows = [SQLMap.LocalGroupApi]::Members($server, $groupName)
        return , @(foreach ($r in $rows) {
            # SID_NAME_USE: 1 user, 2 group, 4 alias (local group), 5 well-known group
            $kind = switch ([int]$r[2]) { 1 { 'User' } { $_ -in 2, 4 } { 'Group' } 5 { 'System' } default { 'Other' } }
            [pscustomobject]@{ Name = $(if ($r[1]) { $r[1] } else { $r[0] }); SID = $r[0]; Kind = $kind }
        })
    }
    catch {
        $netError = Get-SQLMapErrorMessage $_
        if (-not $CimSession -and -not $IsLocal) { throw "Net API: $netError" }
        Add-SQLMapLog $Context "Local Administrators through the Net API failed ($netError); trying WMI"
    }
    $p = @{ ErrorAction = 'Stop'; OperationTimeoutSec = 15 }
    if ($CimSession) { $p.CimSession = $CimSession }
    $group = Get-CimInstance @p -ClassName Win32_Group -Filter "SID = 'S-1-5-32-544' AND LocalAccount = TRUE"
    if (-not $group) { return $null }
    $members = @(Get-CimAssociatedInstance @p -InputObject $group -Association Win32_GroupUser)
    , @(foreach ($m in $members) {
        $kind = switch -Wildcard ($m.CimClass.CimClassName) { 'Win32_Group' { 'Group' } 'Win32_SystemAccount' { 'System' } default { 'User' } }
        [pscustomobject]@{ Name = "$($m.Domain)\$($m.Name)"; SID = [string]$m.SID; Kind = $kind }
    })
}

function Get-SQLMapCimHostInfo {
    # OS, hardware and virtualization info (cores matter for licensing).
    param([hashtable]$Context, $CimSession)
    $p = @{ ErrorAction = 'Stop' }
    if ($CimSession) { $p.CimSession = $CimSession }
    $info = [ordered]@{
        OSCaption = $null; OSVersion = $null; OSArchitecture = $null; LastBootTime = $null
        ComputerName = $null; Domain = $null; Manufacturer = $null; Model = $null; IsVirtual = $null
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
        $cs = Get-CimInstance @p -ClassName Win32_ComputerSystem -Property Name, Domain, Manufacturer, Model, NumberOfLogicalProcessors, TotalPhysicalMemory
        $info.ComputerName      = $cs.Name   # the machine's real name, whatever name was used to reach it
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
