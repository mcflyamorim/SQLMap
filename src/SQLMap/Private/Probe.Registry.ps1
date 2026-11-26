# Registry probe. Two interchangeable "readers":
#   DotNet - [RegistryKey]::OpenRemoteBaseKey (Remote Registry service, current Windows identity only)
#   Cim    - WMI StdRegProv through a CIM session (supports -Credential)

$script:HKLM = [uint32]2147483650   # 0x80000002

function Open-SQLMapRegistryReader {
    param(
        [ValidateSet('DotNet', 'Cim')][string]$Kind,
        [string]$ComputerName,
        [bool]$IsLocal,
        $CimSession
    )
    if ($Kind -eq 'Cim') {
        return @{ Kind = 'Cim'; Session = $CimSession }
    }
    $view = [Microsoft.Win32.RegistryView]::Registry64
    $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
    $key = if ($IsLocal) { [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view) }
           else { [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($hive, $ComputerName, $view) }
    @{ Kind = 'DotNet'; Key = $key }
}

function Close-SQLMapRegistryReader {
    param([hashtable]$Reader)
    if ($Reader -and $Reader.Kind -eq 'DotNet' -and $Reader.Key) { $Reader.Key.Close() }
}

function Invoke-SQLMapStdRegProv {
    param([hashtable]$Reader, [string]$Method, [hashtable]$Arguments)
    $p = @{
        Namespace   = 'root/default'
        ClassName   = 'StdRegProv'
        MethodName  = $Method
        Arguments   = $Arguments
        ErrorAction = 'Stop'
    }
    if ($Reader.Session) { $p.CimSession = $Reader.Session }
    Invoke-CimMethod @p
}

function Get-SQLMapRegSubKey {
    # Returns subkey names, or $null when the key does not exist.
    param([hashtable]$Reader, [string]$Path)
    if ($Reader.Kind -eq 'DotNet') {
        $k = $Reader.Key.OpenSubKey($Path)
        if (-not $k) { return $null }
        try { return , @($k.GetSubKeyNames()) } finally { $k.Close() }
    }
    $r = Invoke-SQLMapStdRegProv $Reader 'EnumKey' @{ hDefKey = $script:HKLM; sSubKeyName = $Path }
    if ($r.ReturnValue -ne 0) { return $null }
    , @($r.sNames)
}

function Get-SQLMapRegValueName {
    param([hashtable]$Reader, [string]$Path)
    if ($Reader.Kind -eq 'DotNet') {
        $k = $Reader.Key.OpenSubKey($Path)
        if (-not $k) { return $null }
        try { return , @($k.GetValueNames()) } finally { $k.Close() }
    }
    $r = Invoke-SQLMapStdRegProv $Reader 'EnumValues' @{ hDefKey = $script:HKLM; sSubKeyName = $Path }
    if ($r.ReturnValue -ne 0) { return $null }
    , @($r.sNames)
}

function Get-SQLMapRegValue {
    param(
        [hashtable]$Reader,
        [string]$Path,
        [string]$Name,
        [ValidateSet('String', 'DWord', 'Binary', 'MultiString')][string]$Type = 'String'
    )
    if ($Reader.Kind -eq 'DotNet') {
        $k = $Reader.Key.OpenSubKey($Path)
        if (-not $k) { return $null }
        try { return $k.GetValue($Name) } finally { $k.Close() }
    }
    $method = @{ String = 'GetStringValue'; DWord = 'GetDWORDValue'; Binary = 'GetBinaryValue'; MultiString = 'GetMultiStringValue' }[$Type]
    $r = Invoke-SQLMapStdRegProv $Reader $method @{ hDefKey = $script:HKLM; sSubKeyName = $Path; sValueName = $Name }
    if ($r.ReturnValue -ne 0) { return $null }
    if ($Type -in 'DWord', 'Binary') { return $r.uValue }
    $r.sValue
}

function Get-SQLMapRegistryInstance {
    # Reads every SQL Engine / SSAS / SSRS / PBIRS instance registered on the computer.
    param([hashtable]$Reader, [string]$ComputerName)

    $roots = @(
        @{ Path = 'SOFTWARE\Microsoft\Microsoft SQL Server'; Wow64 = $false },
        @{ Path = 'SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server'; Wow64 = $true }
    )
    $typeMap = [ordered]@{ SQL = 'Engine'; OLAP = 'SSAS'; RS = 'SSRS' }
    $found = @{}
    $clusterNodes = $null

    foreach ($root in $roots) {
        $rootKeys = Get-SQLMapRegSubKey $Reader $root.Path
        if ($null -eq $rootKeys) { continue }

        if ($rootKeys -contains 'Instance Names') {
            foreach ($kind in $typeMap.Keys) {
                $namesPath = "$($root.Path)\Instance Names\$kind"
                $names = Get-SQLMapRegValueName $Reader $namesPath
                if (-not $names) { continue }
                foreach ($name in $names) {
                    if ([string]::IsNullOrEmpty($name)) { continue }
                    $id = [string](Get-SQLMapRegValue $Reader $namesPath $name)
                    $serviceType = $typeMap[$kind]
                    if ($serviceType -eq 'SSRS' -and ($name -eq 'PBIRS' -or $id -eq 'PBIRS')) { $serviceType = 'PBIRS' }
                    $key = "$serviceType|$name".ToUpperInvariant()
                    if ($found.ContainsKey($key)) { continue }

                    $base = "$($root.Path)\$id"
                    $setup = "$base\Setup"
                    $edition    = Get-SQLMapRegValue $Reader $setup 'Edition'
                    $patchLevel = Get-SQLMapRegValue $Reader $setup 'PatchLevel'
                    $rtmVersion = Get-SQLMapRegValue $Reader $setup 'Version'
                    $version = if ($patchLevel) { $patchLevel } elseif ($rtmVersion) { $rtmVersion } else {
                        Get-SQLMapRegValue $Reader "$base\MSSQLServer\CurrentVersion" 'CurrentVersion'
                    }

                    $inst = [ordered]@{
                        ServiceType      = $serviceType
                        InstanceName     = $name
                        InstanceId       = $id
                        Edition          = $edition
                        Version          = $version
                        Wow64            = $root.Wow64
                        Clustered        = $false
                        ClusterName      = $null
                        ClusterNodes     = @()
                        TcpPort          = $null
                        DynamicPort      = $null
                        LastHeartbeatUtc = $null
                        Components       = @()
                    }

                    if ($serviceType -eq 'Engine') {
                        $idKeys = Get-SQLMapRegSubKey $Reader $base
                        # Instance-aware features leave their own subkey under MSSQLnn.<instance>
                        if ($idKeys -and $idKeys -contains 'MSSearch') { $inst.Components += 'Full-Text' }
                        if ($idKeys -and $idKeys -contains 'Polybase') { $inst.Components += 'PolyBase' }
                        if ($idKeys -and $idKeys -contains 'Cluster') {
                            $inst.Clustered = $true
                            $inst.ClusterName = Get-SQLMapRegValue $Reader "$base\Cluster" 'ClusterName'
                            if ($null -eq $clusterNodes) {
                                $clusterNodes = @()
                                $nodeIds = Get-SQLMapRegSubKey $Reader 'Cluster\Nodes'
                                foreach ($n in @($nodeIds)) {
                                    if (-not $n) { continue }
                                    $nn = Get-SQLMapRegValue $Reader "Cluster\Nodes\$n" 'NodeName'
                                    if ($nn) { $clusterNodes += [string]$nn }
                                }
                            }
                            $inst.ClusterNodes = @($clusterNodes)
                        }
                        $tcp = "$base\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
                        $static  = [string](Get-SQLMapRegValue $Reader $tcp 'TcpPort')
                        $dynamic = [string](Get-SQLMapRegValue $Reader $tcp 'TcpDynamicPorts')
                        $p = 0
                        if ($static -and [int]::TryParse(($static -split ',')[0].Trim(), [ref]$p) -and $p -gt 0) {
                            $inst.TcpPort = $p; $inst.DynamicPort = $false
                        }
                        elseif ($dynamic -and [int]::TryParse(($dynamic -split ',')[0].Trim(), [ref]$p) -and $p -gt 0) {
                            $inst.TcpPort = $p; $inst.DynamicPort = $true
                        }
                        # SQL Server refreshes this value about every minute while the service is running
                        $hb = Get-SQLMapRegValue $Reader "$base\MSSQLServer" 'uptime_time_utc' -Type Binary
                        if ($hb) { $inst.LastHeartbeatUtc = ConvertFrom-SQLMapFileTime ([byte[]]$hb) }
                    }
                    $found[$key] = [pscustomobject]$inst
                }
            }
        }

        # Integration Services is shared (one per version), registered under <ver>\DTS\Setup.
        # SSMS/SSDT also create DTS keys, so require the server feature (SQL_DTS_Full).
        foreach ($ver in ($rootKeys | Where-Object { $_ -match '^\d{2,3}$' })) {
            $setup = "$($root.Path)\$ver\DTS\Setup"
            $features = [string](Get-SQLMapRegValue $Reader $setup 'FeatureList')
            $edition  = Get-SQLMapRegValue $Reader $setup 'Edition'
            if (-not (($features -match 'SQL_DTS_Full') -or (-not $features -and $edition))) { continue }
            $name = "SSIS$ver"
            $key = "SSIS|$name".ToUpperInvariant()
            if ($found.ContainsKey($key)) { continue }
            $patch = Get-SQLMapRegValue $Reader $setup 'PatchLevel'
            $found[$key] = [pscustomobject][ordered]@{
                ServiceType = 'SSIS'; InstanceName = $name; InstanceId = "$ver\DTS"; Edition = $edition
                Version = $(if ($patch) { $patch } else { Get-SQLMapRegValue $Reader $setup 'Version' })
                Wow64 = $root.Wow64; Clustered = $false; ClusterName = $null; ClusterNodes = @()
                TcpPort = $null; DynamicPort = $null; LastHeartbeatUtc = $null; Components = @()
            }
        }

        # SQL Server 2000 era: only the InstalledInstances list is reliable
        $installed = Get-SQLMapRegValue $Reader $root.Path 'InstalledInstances' -Type MultiString
        foreach ($name in @($installed)) {
            if (-not $name) { continue }
            $key = "Engine|$name".ToUpperInvariant()
            if ($found.ContainsKey($key)) { continue }
            $found[$key] = [pscustomobject][ordered]@{
                ServiceType = 'Engine'; InstanceName = $name; InstanceId = $null; Edition = $null; Version = $null
                Wow64 = $root.Wow64; Clustered = $false; ClusterName = $null; ClusterNodes = @()
                TcpPort = $null; DynamicPort = $null; LastHeartbeatUtc = $null; Components = @()
            }
        }
    }
    @($found.Values)
}

function Invoke-SQLMapRegistryProbe {
    param(
        [hashtable]$Context,
        [string]$ComputerName,
        [bool]$IsLocal,
        [bool]$SmbReachable,
        [pscredential]$Credential,
        $CimSession,
        [bool]$CimAvailable
    )
    $result = [ordered]@{ Status = 'Skipped'; Method = $null; Instances = @(); Message = $null }

    $order = @()
    if ($IsLocal) { $order = @('DotNet') }
    elseif ($Credential) { $order = @('Cim', 'DotNet') }
    else { $order = @('DotNet', 'Cim') }

    $errors = @()
    foreach ($kind in $order) {
        if ($kind -eq 'Cim' -and -not $CimAvailable) { continue }
        if ($kind -eq 'DotNet' -and -not $IsLocal -and -not $SmbReachable) {
            $errors += 'RemoteRegistry: skipped, TCP 445 closed'
            continue
        }
        $reader = $null
        try {
            $reader = Open-SQLMapRegistryReader -Kind $kind -ComputerName $ComputerName -IsLocal $IsLocal -CimSession $CimSession
            $result.Instances = @(Get-SQLMapRegistryInstance -Reader $reader -ComputerName $ComputerName)
            $result.Method = if ($kind -eq 'Cim') { 'WMI StdRegProv' } else { if ($IsLocal) { 'Local registry' } else { 'Remote Registry' } }
            $result.Status = 'OK'
            Add-SQLMapLog $Context "Registry ($($result.Method)): $($result.Instances.Count) instance(s) registered"
            return $result
        }
        catch {
            $kindText = if ($kind -eq 'Cim') { 'WMI StdRegProv' } else { 'Remote Registry' }
            $result.Status = Get-SQLMapErrorKind $_
            $msg = Get-SQLMapErrorMessage $_
            # TCP 445 answered, so 'network path not found' means the winreg pipe is missing: service stopped
            if ($kind -eq 'DotNet' -and $msg -match 'network path was not found|caminho de rede') { $msg += ' (the Remote Registry service is probably stopped on the target)' }
            $errors += "${kindText}: $msg"
            Add-SQLMapLog $Context "Registry via $kindText failed: $msg" -Level Warning
        }
        finally { Close-SQLMapRegistryReader $reader }
    }
    if ($errors) { $result.Message = $errors -join ' | ' }
    if ($result.Status -eq 'Skipped' -and $errors) { $result.Status = 'Unavailable' }
    $result
}
