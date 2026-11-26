function Invoke-SQLMapComputerScan {
    <#
    .SYNOPSIS
        Scans one computer for SQL Server services.
    .DESCRIPTION
        Runs the selected probes against a single computer and returns a host result object
        (with an Instances property). Invoke-SQLMapScan calls this in parallel for many hosts.

        Probes:
          Ping       ICMP echo (failure does not stop the scan; many servers block ICMP)
          Tcp        TCP connect to the SQL ports in -TcpPort
          Browser    SQL Server Browser (UDP 1434)
          Registry   Remote Registry, falling back to WMI StdRegProv (needs -Credential to use other credentials)
          Service    Windows services + OS/hardware info through CIM (WSMan, falling back to DCOM)
          SqlConnect Connects to each running engine and runs read-only queries (not in the default set)

        Management ports 135, 445 and 5985 are always checked so unavailable probes are skipped quickly.
    .EXAMPLE
        Invoke-SQLMapComputerScan -Target SRV01 -Probe Ping,Tcp,Browser,Registry,Service,SqlConnect
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Alias('ComputerName')]
        $Target,

        [ValidateSet('Ping', 'Tcp', 'Browser', 'Registry', 'Service', 'SqlConnect')]
        [string[]]$Probe = @('Ping', 'Tcp', 'Browser', 'Registry', 'Service'),

        [int[]]$TcpPort = @(1433),
        [pscredential]$Credential,
        [pscredential]$SqlCredential,
        [ValidateRange(200, 60000)][int]$TimeoutMs = 1500
    )
    process {
        if ($Target -is [string]) {
            $Target = New-SQLMapTarget -ComputerName (ConvertTo-SQLMapComputerName $Target) -Source 'Manual'
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $started = Get-Date
        $name = $Target.ComputerName
        $ctx = New-SQLMapContext -ComputerName $Target.ShortName
        $isLocal = Test-SQLMapLocalComputer $name
        $mgmtPorts = @(135, 445, 5985)

        $h = [ordered]@{
            ComputerName      = $Target.ShortName
            DnsName           = $null
            IPAddress         = $null
            Sources           = @($Target.Sources)
            AdOperatingSystem = $Target.OperatingSystem
            Status            = 'Unknown'
            StatusDetail      = $null
            IsLocal           = $isLocal
            Reachable         = $false
            PingOK            = $null
            OpenPorts         = @()
            Probes            = [ordered]@{ Dns = 'Skipped'; Ping = 'Skipped'; Tcp = 'Skipped'; Browser = 'Skipped'; Registry = 'Skipped'; Service = 'Skipped'; Prelogin = 'Skipped'; SqlConnect = 'Skipped' }
            ProbeMessages     = [ordered]@{}
            HostInfo          = $null
            Services          = @()
            LocalAdmins       = $null   # members of the local Administrators group; $null = not read
            SPNs              = @($Target.SPNs)
            Instances         = @()
            InstanceCount     = 0
            InstanceTypes     = $null   # 'Engine 1, SSRS 1': InstanceCount includes every service type
            EngineCount       = 0
            ScanStart         = ConvertTo-SQLMapIsoDate $started
            DurationMs        = $null
            Log               = @()
        }

        $cim = $null
        try {
            # --- DNS ---------------------------------------------------------------------
            $dns = Resolve-SQLMapHost -ComputerName $name -IPAddressHint $Target.IPAddress -TimeoutMs ([Math]::Max($TimeoutMs, 2000))
            $h.Probes.Dns = $dns.Status
            if ($dns.Message) { $h.ProbeMessages.Dns = $dns.Message }
            $h.DnsName = $dns.DnsName
            $h.IPAddress = @($dns.IPAddresses) | Select-Object -First 1
            # IP-range targets: show the reverse-DNS name when we got one
            $ipTmp = $null
            if ($isLocal) {
                $h.ComputerName = $env:COMPUTERNAME
                $ctx.ComputerName = $h.ComputerName
            }
            elseif ([System.Net.IPAddress]::TryParse($Target.ShortName, [ref]$ipTmp) -and $dns.DnsName -and $dns.DnsName -ne $Target.ShortName) {
                $h.ComputerName = (Get-SQLMapShortName $dns.DnsName).ToUpperInvariant()
                $ctx.ComputerName = $h.ComputerName
            }
            if (-not $h.IPAddress -and -not $isLocal) {
                $h.Status = 'Unresolved'
                $h.StatusDetail = "Name could not be resolved: $($dns.Message)"
                Add-SQLMapLog $ctx $h.StatusDetail -Level Warning
                return
            }
            $address = if ($isLocal) { 'localhost' } elseif ($h.IPAddress) { $h.IPAddress } else { $name }
            # Names (not IPs) keep Kerberos happy for RPC/WMI/SQL
            $connectName = if ($isLocal) { $env:COMPUTERNAME } elseif ($dns.DnsName) { $dns.DnsName } else { $name }

            # --- Ping --------------------------------------------------------------------
            if ($Probe -contains 'Ping') {
                $h.PingOK = Test-SQLMapPing -Address $address -TimeoutMs $TimeoutMs
                $h.Probes.Ping = if ($h.PingOK) { 'OK' } else { 'NoReply' }
            }

            # --- TCP ---------------------------------------------------------------------
            # SQL ports: -TcpPort plus the ports in the host's MSSQLSvc SPNs ('MSSQLSvc/host:56615'). SPNs are readable
            # without admin rights, so they find named instances on hosts whose registry/services are closed to us.
            $spnPorts = @(foreach ($s in @($h.SPNs)) { $m = [regex]::Match([string]$s, ':(\d{1,5})$'); if ($m.Success) { [int]$m.Groups[1].Value } })
            $sqlPorts = if ($Probe -contains 'Tcp') { @(@($TcpPort) + $spnPorts | Where-Object { $_ -gt 0 -and $_ -le 65535 } | Select-Object -Unique) } else { @() }
            $open = @()
            if (-not $isLocal -or $sqlPorts) {
                $open = Test-SQLMapTcpPort -Address $address -Port (@($sqlPorts) + $mgmtPorts) -TimeoutMs $TimeoutMs
            }
            $h.OpenPorts = @($open)
            if ($Probe -contains 'Tcp') { $h.Probes.Tcp = if ($open | Where-Object { $_ -in $sqlPorts }) { 'Open' } else { 'Closed' } }
            $openSqlPorts = @($open | Where-Object { $_ -in $sqlPorts })

            $h.Reachable = $isLocal -or $h.PingOK -or ($open.Count -gt 0)
            if (-not $h.Reachable) {
                $h.Status = 'Unreachable'
                $h.StatusDetail = 'No ICMP reply and no open TCP port (' + ((@($sqlPorts) + $mgmtPorts) -join ', ') + ')'
                Add-SQLMapLog $ctx $h.StatusDetail -Level Warning
                return
            }
            Add-SQLMapLog $ctx ("Reachable. Open ports: " + $(if ($open) { $open -join ', ' } else { 'none' }))

            # --- Browser -----------------------------------------------------------------
            $browserInstances = @()
            if ($Probe -contains 'Browser') {
                $b = Get-SQLMapBrowserInstance -Address $address -TimeoutMs $TimeoutMs
                $h.Probes.Browser = $b.Status
                if ($b.Message -and $b.Status -ne 'OK') { $h.ProbeMessages.Browser = $b.Message }
                $browserInstances = @($b.Instances)
                if ($b.Status -eq 'OK') { Add-SQLMapLog $ctx "Browser replied with $($browserInstances.Count) instance(s)" }
            }

            # --- CIM session (services, host info, registry fallback) ----------------------
            $needCim = ($Probe -contains 'Service') -or ($Probe -contains 'Registry')
            if ($needCim) {
                $cim = Connect-SQLMapCim -Context $ctx -ComputerName $connectName -IsLocal $isLocal -OpenPorts $open -PortsKnown $true -Credential $Credential -TimeoutSec ([Math]::Max(5, [int]($TimeoutMs / 100)))
            }

            # --- Registry ----------------------------------------------------------------
            $regInstances = @()
            if ($Probe -contains 'Registry') {
                $reg = Invoke-SQLMapRegistryProbe -Context $ctx -ComputerName $connectName -IsLocal $isLocal `
                    -SmbReachable ($open -contains 445) -Credential $Credential `
                    -CimSession $cim.Session -CimAvailable ($cim.Status -eq 'OK')
                $h.Probes.Registry = $reg.Status
                if ($reg.Message) { $h.ProbeMessages.Registry = $reg.Message }
                if ($reg.Method) { $h.ProbeMessages.RegistryMethod = $reg.Method }
                $regInstances = @($reg.Instances)
            }

            # --- Services + host info -------------------------------------------------------
            if ($Probe -contains 'Service') {
                if ($cim.Status -eq 'OK') {
                    try {
                        $h.Services = @(Get-SQLMapCimService -Context $ctx -CimSession $cim.Session | Sort-Object ServiceType, InstanceName, Name)
                        $h.Probes.Service = 'OK'
                        Add-SQLMapLog $ctx "Services: $($h.Services.Count) SQL-related service(s)"
                    }
                    catch {
                        $h.Probes.Service = Get-SQLMapErrorKind $_
                        $h.ProbeMessages.Service = Get-SQLMapErrorMessage $_
                        Add-SQLMapLog $ctx "Service query failed: $($h.ProbeMessages.Service)" -Level Warning
                    }
                    $h.HostInfo = Get-SQLMapCimHostInfo -Context $ctx -CimSession $cim.Session
                    # Local Administrators: used after the scan to tell where service accounts are local admin
                    try {
                        $la = Get-SQLMapLocalAdmin -Context $ctx -ComputerName $connectName -IsLocal $isLocal -CimSession $cim.Session
                        if ($null -ne $la) {
                            $h.LocalAdmins = @($la)
                            Add-SQLMapLog $ctx "Local Administrators: $(@($la).Count) member(s)"
                        }
                        else { Add-SQLMapLog $ctx 'Local Administrators: none (domain controller: no local groups)' }
                    }
                    catch { Add-SQLMapLog $ctx "Local Administrators not readable: $(Get-SQLMapErrorMessage $_)" -Level Warning }
                }
                else {
                    $h.Probes.Service = $cim.Status
                    if ($cim.Message) { $h.ProbeMessages.Service = $cim.Message }
                }
            }

            # --- Merge evidence -----------------------------------------------------------
            $authoritative = ($h.Probes.Registry -eq 'OK') -or ($h.Probes.Service -eq 'OK')
            $instances = Merge-SQLMapInstance -ComputerName $h.ComputerName -Registry $regInstances -Services $h.Services `
                -Browser $browserInstances -SPN $h.SPNs -InstanceHint $Target.InstanceHints `
                -OpenSqlPorts $openSqlPorts -SpnOwner @($Target.SpnOwners | Where-Object { $_ }) -AuthoritativeOK $authoritative

            # --- TDS pre-login: exact build of each listening engine, no login needed -------
            # (registry PatchLevel is already exact; Browser/port/SPN-only engines get their real build here)
            if ($Probe -contains 'Tcp') {
                $plResults = @()
                $notSql = @()
                foreach ($i in @($instances | Where-Object { $_.ServiceType -eq 'Engine' -and $_.TcpPort })) {
                    if ($i.VersionSource -eq 'Registry') { continue }
                    if ($i.ServiceState -and $i.ServiceState -ne 'Running') { continue }
                    $pl = Get-SQLMapTdsPrelogin -Address $address -Port ([int]$i.TcpPort) -TimeoutMs $TimeoutMs
                    $plResults += $pl.Status
                    if ($pl.Status -eq 'OK') {
                        Add-SQLMapEvidence $i 'Prelogin'
                        $i.Version = $pl.Version
                        $i.VersionSource = 'Prelogin'
                        Add-SQLMapLog $ctx "TDS pre-login on port $($i.TcpPort): SQL Server $($pl.Version) (encryption: $($pl.Encryption))"
                    }
                    else {
                        Add-SQLMapLog $ctx ("TDS pre-login on port $($i.TcpPort): $($pl.Status)" + $(if ($pl.Message) { " - $($pl.Message)" } else { '' }))
                        # Only an open port pointed to this instance, and it does not speak TDS: not a SQL Server
                        if ($pl.Status -eq 'NotSql' -and -not @($i.DetectedBy | Where-Object { $_ -ne 'TcpPort' }).Count) { $notSql += $i }
                    }
                }
                if ($notSql.Count) {
                    $instances = @($instances | Where-Object { $notSql -notcontains $_ })
                    Add-SQLMapLog $ctx "Port(s) $((@($notSql | ForEach-Object { $_.TcpPort })) -join ', ') open but not SQL Server: ignored"
                }
                $h.Probes.Prelogin = if (-not $plResults) { 'NoTarget' } elseif ($plResults -contains 'OK') { 'OK' } else { $plResults[0] }
            }

            # --- SQL connection -----------------------------------------------------------
            if ($Probe -contains 'SqlConnect') {
                $results = @()
                foreach ($i in ($instances | Where-Object { $_.ServiceType -eq 'Engine' })) {
                    if ($i.InstanceName -eq 'MICROSOFT##WID') { continue }
                    if ($i.ServiceState -and $i.ServiceState -ne 'Running') { continue }
                    $server = if ($i.Clustered -and $i.ClusterName) { $i.ClusterName } else { $connectName }
                    $ds = if ($i.TcpPort) { "$server,$($i.TcpPort)" }
                          elseif ($i.InstanceName -eq 'MSSQLSERVER') { $server }
                          else { "$server\$($i.InstanceName)" }
                    $sqlTimeout = [Math]::Max(3, [int]($TimeoutMs / 300))
                    $acctArgs = @{ ServiceAccount = $i.ServiceAccount; AgentAccount = $i.AgentServiceAccount }
                    $sc = Invoke-SQLMapSqlConnect -Context $ctx -DataSource $ds -SqlCredential $SqlCredential -TimeoutSec $sqlTimeout @acctArgs

                    # Kerberos failure ('Cannot generate SSPI context'): the MSSQLSvc SPN is missing or registered
                    # to another account. Worth reporting; retry by IP address, which makes Windows use NTLM.
                    if ($sc.Status -ne 'OK' -and $sc.Message -match 'SSPI|target principal name' -and -not $SqlCredential -and
                        -not $isLocal -and -not $i.Clustered -and $h.IPAddress) {
                        $ipDs = if ($i.TcpPort) { "$($h.IPAddress),$($i.TcpPort)" } elseif ($i.InstanceName -eq 'MSSQLSERVER') { $h.IPAddress } else { "$($h.IPAddress)\$($i.InstanceName)" }
                        Add-SQLMapLog $ctx "SqlConnect ${ds}: Kerberos failed (SPN problem); retrying by IP address with NTLM" -Level Warning
                        $sc2 = Invoke-SQLMapSqlConnect -Context $ctx -DataSource $ipDs -SqlCredential $SqlCredential -TimeoutSec $sqlTimeout @acctArgs
                        $i.Notes.Add('Kerberos authentication failed ("' + $sc.Message + '"): the MSSQLSvc SPN is missing, duplicated or registered to another account' +
                            $(if ($sc2.Status -eq 'OK') { '. Connected with NTLM through the IP address.' } else { '.' }))
                        if ($sc2.Status -eq 'OK') { $sc = $sc2 }
                    }
                    # Handshake timeout before login: usually a TLS protocol mismatch
                    if ($sc.Status -ne 'OK' -and $sc.Message -match 'pre-login handshake') {
                        $sc.Message += ' Likely a TLS mismatch: e.g. SQL Server without TLS 1.2 support, or old TLS versions disabled on one side.'
                        Add-SQLMapLog $ctx "SqlConnect ${ds}: pre-login handshake failed - likely a TLS version mismatch between this computer and the server"
                    }
                    $results += $sc.Status
                    $i.SqlConnectStatus = $sc.Status
                    $i.SqlConnectMessage = $sc.Message
                    if ($sc.Status -eq 'OK') {
                        Add-SQLMapEvidence $i 'SqlConnect'
                        $i.Version           = $sc.ProductVersion
                        $i.VersionSource     = 'SqlConnect'
                        $i.Edition           = $sc.Edition
                        $i.ProductLevel      = $sc.ProductLevel
                        $i.UpdateLevel       = $sc.ProductUpdateLevel
                        $i.UpdateReference   = $sc.ProductUpdateReference
                        $i.ServerName        = $sc.ServerName
                        $i.Collation         = $sc.Collation
                        $i.IsHadrEnabled     = if ($null -ne $sc.IsHadrEnabled) { [bool]$sc.IsHadrEnabled } else { $null }
                        $i.DatabaseCount     = $sc.DatabaseCount
                        $i.DataSizeGB        = $sc.DataSizeGB
                        $i.LogSizeGB         = $sc.LogSizeGB
                        $i.MaxServerMemoryMB = $sc.MaxServerMemoryMB
                        $i.CpuCount          = $sc.CpuCount
                        $i.SqlStartTime      = $sc.StartTime
                        # Service accounts without Windows admin rights (sys.dm_server_services, VIEW SERVER STATE)
                        if (-not $i.ServiceAccount -and $sc.ServiceAccount) { $i.ServiceAccount = $sc.ServiceAccount; $i.ServiceAccountSource = 'SQL connection' }
                        if (-not $i.AgentServiceAccount -and $sc.AgentServiceAccount) { $i.AgentServiceAccount = $sc.AgentServiceAccount }
                        # States and start modes without Windows admin rights (the Windows services, when read, win)
                        if (-not $i.AgentState -and $sc.AgentState) { $i.AgentState = $sc.AgentState }
                        if (-not $i.AgentStartMode -and $sc.AgentStartMode) { $i.AgentStartMode = $sc.AgentStartMode }
                        if (-not $i.StartMode -and $sc.StartMode) { $i.StartMode = $sc.StartMode }
                        if (-not $i.ServiceState -and $sc.ServiceState) { $i.ServiceState = $sc.ServiceState }
                        # Security: logins of the service accounts, sysadmins, auth mode, sa, linked servers, AGs
                        foreach ($k in 'ServiceAccountLogin', 'AgentAccountLogin', 'AuthenticationMode', 'SaLogin', 'ScanLoginSysadmin',
                                       'SysadminLogins', 'LinkedServers', 'AvailabilityGroups') { $i[$k] = $sc.$k }
                        if ($sc.IsClustered -eq 1) { $i.Clustered = $true }
                        $i.SsisCatalog = ($sc.HasSsisCatalog -gt 0)
                        if ($i.SsisCatalog) { Add-SQLMapComponent $i 'SSISDB catalog' }
                    }
                }
                $h.Probes.SqlConnect = if (-not $results) { 'NoTarget' }
                                       elseif ($results -contains 'OK') { if (@($results | Where-Object { $_ -ne 'OK' }).Count) { 'Partial' } else { 'OK' } }
                                       else { $results[0] }
            }

            $asOf = Get-Date
            $h.Instances = @($instances | ForEach-Object { Complete-SQLMapInstance -Instance $_ -AsOf $asOf } | Sort-Object ServiceType, InstanceName)
            $h.InstanceCount = $h.Instances.Count
            $h.InstanceTypes = Get-SQLMapInstanceTypeText $h.Instances
            $h.EngineCount   = @($h.Instances | Where-Object { $_.ServiceType -eq 'Engine' }).Count

            if ($h.InstanceCount -gt 0) { $h.Status = 'SQLFound' }
            elseif ($authoritative) { $h.Status = 'NoSQLFound' }
            else {
                $h.Status = 'Inconclusive'
                $h.StatusDetail = if ($h.Probes.Registry -eq 'AccessDenied' -or $h.Probes.Service -eq 'AccessDenied') {
                    'Access denied: the scan account cannot read the registry or the services of this host (it needs to be local ' +
                    "administrator; use the Credentials tab or -Credential). Registry=$($h.Probes.Registry), Service=$($h.Probes.Service)"
                }
                else {
                    'Host is reachable but neither the registry nor the services could be read: ' +
                    "Registry=$($h.Probes.Registry), Service=$($h.Probes.Service)"
                }
            }
        }
        catch {
            $h.Status = 'Error'
            $h.StatusDetail = Get-SQLMapErrorMessage $_
            # Where it failed (function, file, line) so bug reports can be traced: 'at Merge-SQLMapInstance, Merge.ps1: line 153'
            $where = ([string]$_.ScriptStackTrace -split "`r?`n" | Select-Object -First 1) -replace '[A-Za-z]:\\[^,]*\\', ''
            Add-SQLMapLog $ctx "Unexpected error: $($h.StatusDetail) ($where)" -Level Error
        }
        finally {
            if ($cim -and $cim.Session) { Remove-CimSession $cim.Session -ErrorAction SilentlyContinue }
            $sw.Stop()
            $h.DurationMs = $sw.ElapsedMilliseconds
            $h.Log = $ctx.Log.ToArray()
            # Emitted here so early 'return' paths (unresolved/unreachable) still produce a result
            [pscustomobject]$h
        }
    }
}
