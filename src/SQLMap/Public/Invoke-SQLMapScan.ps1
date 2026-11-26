function Invoke-SQLMapScan {
    <#
    .SYNOPSIS
        Discovers computers and scans them in parallel for SQL Server services.
    .DESCRIPTION
        Runs Find-SQLMapTarget (or uses -Target), then Invoke-SQLMapComputerScan for every target
        on a runspace pool. Returns a scan object (Hosts, Instances, Summary) that
        Export-SQLMapReport turns into HTML/JSON/CSV.

        -State lets a UI follow and control the scan from another runspace. Pass a synchronized
        hashtable; the scan keeps these keys updated:
          Phase, Total, Completed, Running   progress counters
          LogQueue   ConcurrentQueue[string] with log lines
          HostQueue  ConcurrentQueue[object] with each finished host result
          CancelRequested   set to $true to stop the scan (finished hosts are kept)
    .EXAMPLE
        $scan = Invoke-SQLMapScan -ActiveDirectory -SPN -SqlConnect -Verbose
    .EXAMPLE
        $scan = Invoke-SQLMapScan -IpRange 10.10.0.0/24 -TcpPort 1433,1434,2383 -Throttle 64
    #>
    [CmdletBinding()]
    param(
        # Discovery
        [string[]]$ComputerName,
        [string]$InputFile,
        [switch]$ActiveDirectory,
        [switch]$SPN,
        [string[]]$IpRange,
        [switch]$Broadcast,
        [string]$Domain,
        [string]$SearchBase,
        [string]$NameFilter = '*',
        [switch]$IncludeWorkstations,
        [int]$ActiveWithinDays = 90,
        [object[]]$Target,

        # Scan
        [ValidateSet('Ping', 'Tcp', 'Browser', 'Registry', 'Service', 'SqlConnect')]
        [string[]]$Probe = @('Ping', 'Tcp', 'Browser', 'Registry', 'Service'),
        [switch]$SqlConnect,
        [int[]]$TcpPort = @(1433),
        [ValidateRange(200, 60000)][int]$TimeoutMs = 1500,
        [ValidateRange(1, 256)][int]$Throttle = 32,
        [ValidateRange(10, 3600)][int]$HostTimeoutSec = 300,
        [pscredential]$Credential,
        [pscredential]$SqlCredential,

        # Output / control
        [string]$LogPath,
        [hashtable]$State
    )

    $started = Get-Date
    if ($State) {
        foreach ($k in 'Phase', 'Total', 'Completed', 'Running', 'CancelRequested') { if (-not $State.ContainsKey($k)) { $State[$k] = $null } }
        if (-not $State.LogQueue)  { $State.LogQueue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]' }
        if (-not $State.HostQueue) { $State.HostQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]' }
        $State.Phase = 'Discovery'; $State.Completed = 0; $State.Running = 0
    }
    $log = { param($msg, $level = 'Info', $computer = '') Write-SQLMapLog -Message $msg -Level $level -ComputerName $computer -LogPath $LogPath -State $State }

    $probes = @($Probe)
    if ($SqlConnect -and $probes -notcontains 'SqlConnect') { $probes += 'SqlConnect' }

    & $log "SQLMap $script:ModuleVersion scan started by $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"

    # --- Discovery -------------------------------------------------------------------
    if ($Target) {
        $targets = @(Merge-SQLMapTarget -Target $Target)
    }
    else {
        $disc = @{}
        foreach ($k in 'ComputerName', 'InputFile', 'ActiveDirectory', 'SPN', 'IpRange', 'Broadcast', 'Domain', 'SearchBase', 'NameFilter', 'IncludeWorkstations', 'ActiveWithinDays', 'Credential') {
            if ($PSBoundParameters.ContainsKey($k)) { $disc[$k] = $PSBoundParameters[$k] }
        }
        $targets = @(Find-SQLMapTarget @disc)
    }
    # Per source (a target found by several sources counts in each): 'ActiveDirectory 98, SPN 14'
    $bySource = @($targets | ForEach-Object { @($_.Sources) } | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    & $log ("Discovery found $($targets.Count) target(s)" + $(if ($bySource) { ": $bySource" } else { '' }))
    if ($State) { $State.Total = $targets.Count; $State.Phase = 'Scanning' }

    # --- Parallel scan ---------------------------------------------------------------
    $hosts = New-Object System.Collections.Generic.List[object]
    $cancelled = $false
    if ($targets.Count -gt 0) {
        $scanParams = @{ Probe = $probes; TcpPort = $TcpPort; TimeoutMs = $TimeoutMs }
        if ($Credential)    { $scanParams.Credential = $Credential }
        if ($SqlCredential) { $scanParams.SqlCredential = $SqlCredential }

        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $iss.ImportPSModule([string[]]@('CimCmdlets', $script:ModuleManifestPath))
        $maxThreads = [Math]::Min($Throttle, $targets.Count)
        $pool = [runspacefactory]::CreateRunspacePool($iss)
        [void]$pool.SetMinRunspaces(1)
        [void]$pool.SetMaxRunspaces($maxThreads)
        $pool.Open()

        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        foreach ($t in $targets) { $queue.Enqueue($t) }
        $running = New-Object System.Collections.Generic.List[object]
        $abandoned = New-Object System.Collections.Generic.List[object]
        $total = $targets.Count
        $lastProgress = [DateTime]::MinValue
        $scanStartedUtc = [DateTime]::UtcNow

        $complete = {
            param($hostResult)
            $hosts.Add($hostResult)
            $lines = foreach ($e in $hostResult.Log) {
                Write-Verbose ("[{0}] {1}" -f $e.ComputerName, $e.Message)
                '[{0}] [{1}] [{2}] {3}' -f $e.Time, $e.Level, $e.ComputerName, $e.Message
            }
            if ($LogPath -and $lines) { try { Add-Content -Path $LogPath -Value $lines -Encoding UTF8 } catch { } }
            if ($State) {
                foreach ($l in $lines) { $State.LogQueue.Enqueue($l) }
                $State.HostQueue.Enqueue($hostResult)
                $State.Completed = $hosts.Count
            }
            $types = if ($hostResult.InstanceTypes) { " ($($hostResult.InstanceTypes))" } else { '' }
            $summaryLine = "$($hostResult.Status): $($hostResult.InstanceCount) instance(s)$types in $($hostResult.DurationMs) ms"
            if ($hostResult.Status -in 'Error', 'Timeout') { & $log $summaryLine 'Warning' $hostResult.ComputerName }
            else { & $log $summaryLine 'Info' $hostResult.ComputerName }
        }

        try {
            while ($queue.Count -gt 0 -or $running.Count -gt 0) {
                if ($State -and $State.CancelRequested -and -not $cancelled) {
                    $cancelled = $true
                    & $log 'Cancellation requested; stopping running hosts' 'Warning'
                    while ($queue.Count -gt 0) {
                        $t = $queue.Dequeue()
                        & $complete (New-SQLMapHostStub -Target $t -Status 'Cancelled' -Detail 'Scan cancelled before this host was scanned')
                    }
                    # .ToArray(): @() on a List[object] throws 'Argument types do not match' in PS 5.1
                    foreach ($j in $running.ToArray()) {
                        [void]$j.PS.BeginStop($null, $null)
                        $abandoned.Add($j)
                        & $complete (New-SQLMapHostStub -Target $j.Target -Status 'Cancelled' -Detail 'Scan cancelled while this host was being scanned')
                    }
                    $running.Clear()
                    break
                }

                while ($running.Count -lt $maxThreads -and $queue.Count -gt 0) {
                    $t = $queue.Dequeue()
                    $ps = [powershell]::Create()
                    $ps.RunspacePool = $pool
                    [void]$ps.AddCommand('SQLMap\Invoke-SQLMapComputerScan').AddParameter('Target', $t).AddParameters($scanParams)
                    $running.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Target = $t; Started = [DateTime]::UtcNow })
                }

                for ($idx = $running.Count - 1; $idx -ge 0; $idx--) {
                    $j = $running[$idx]
                    if ($j.Handle.IsCompleted) {
                        $res = $null; $err = $null
                        try { $res = $j.PS.EndInvoke($j.Handle) | Select-Object -Last 1 }
                        catch { $err = Get-SQLMapErrorMessage $_ }
                        if (-not $res) {
                            if (-not $err -and $j.PS.Streams.Error.Count) { $err = [string]$j.PS.Streams.Error[0] }
                            $res = New-SQLMapHostStub -Target $j.Target -Status 'Error' -Detail $err
                        }
                        $j.PS.Dispose()
                        $running.RemoveAt($idx)
                        & $complete $res
                    }
                    elseif (([DateTime]::UtcNow - $j.Started).TotalSeconds -gt $HostTimeoutSec) {
                        [void]$j.PS.BeginStop($null, $null)
                        $abandoned.Add($j)
                        $running.RemoveAt($idx)
                        & $complete (New-SQLMapHostStub -Target $j.Target -Status 'Timeout' -Detail "Host scan exceeded $HostTimeoutSec seconds")
                    }
                }

                if ($State) { $State.Running = $running.Count }
                if (([DateTime]::UtcNow - $lastProgress).TotalMilliseconds -ge 500) {
                    $lastProgress = [DateTime]::UtcNow
                    $pct = [int](100 * $hosts.Count / $total)
                    $wp = @{ Id = 1; Activity = 'SQLMap scan'; Status = "$($hosts.Count) of $total hosts done ($pct%), $($running.Count) running"; PercentComplete = $pct }
                    # Time left from the average pace so far (same rule as the UI: after 1% of the hosts or 5 seconds)
                    $scanSeconds = ([DateTime]::UtcNow - $scanStartedUtc).TotalSeconds
                    if ($hosts.Count -ge [Math]::Max(3, [int]($total * 0.01)) -and $scanSeconds -ge 5 -and $hosts.Count -lt $total) {
                        $wp.SecondsRemaining = [int]($scanSeconds / $hosts.Count * ($total - $hosts.Count))
                    }
                    Write-Progress @wp
                }
                if ($running.Count -gt 0) { Start-Sleep -Milliseconds 100 }
            }
        }
        finally {
            Write-Progress -Id 1 -Activity 'SQLMap scan' -Completed
            # Ctrl+C or an exception: stop whatever is still running
            foreach ($j in $running) { try { [void]$j.PS.BeginStop($null, $null) } catch { } }
            try { $pool.Close(); $pool.Dispose() } catch { }
        }
    }

    # --- Assemble result -------------------------------------------------------------
    $ended = Get-Date
    $hostList = @(Merge-SQLMapHostResult -Hosts $hosts.ToArray() | Sort-Object ComputerName)
    $instances = @($hostList | ForEach-Object { $_.Instances } | Where-Object { $_ })
    $scan = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Tool          = 'SQLMap'
        ToolVersion   = $script:ModuleVersion
        ScanId        = [guid]::NewGuid().ToString()
        StartTime     = ConvertTo-SQLMapIsoDate $started
        EndTime       = ConvertTo-SQLMapIsoDate $ended
        DurationSec   = [math]::Round(($ended - $started).TotalSeconds, 1)
        RunBy         = "$env:USERDOMAIN\$env:USERNAME"
        RunFrom       = $env:COMPUTERNAME
        Cancelled     = $cancelled
        Parameters    = [pscustomobject][ordered]@{
            Discovery      = @($targets | ForEach-Object { $_.Sources } | Select-Object -Unique)
            Probes         = $probes
            TcpPorts       = $TcpPort
            TimeoutMs      = $TimeoutMs
            Throttle       = $Throttle
            Credential     = $(if ($Credential) { $Credential.UserName } else { 'Current user' })
            SqlCredential  = $(if ($SqlCredential) { $SqlCredential.UserName } elseif ($probes -contains 'SqlConnect') { 'Windows authentication' } else { $null })
            BuildReference = (Get-SQLMapBuildReference).LastUpdated
            BuildReferenceMaxAgeDays = (Get-SQLMapBuildReference).MaxAgeDays
        }
        Summary       = $null
        Hosts         = @($hostList | Select-Object -Property * -ExcludeProperty Instances)
        Instances     = $instances
    }
    $scan.Summary = Get-SQLMapSummary -Scan $scan
    if ($State) { $State.Phase = if ($cancelled) { 'Cancelled' } else { 'Done' } }
    & $log ("Scan finished in {0}s: {1} host(s), {2} with SQL, {3} instance(s)" -f $scan.DurationSec, $scan.Summary.Targets, $scan.Summary.HostsWithSql, $scan.Summary.Instances)
    if ($scan.Summary.HostsAccessDenied) {
        & $log ("{0} host(s) could not be verified because access was denied to the registry and services. Run the scan with an account " +
                "that is local administrator on the targets (Credentials tab, or -Credential)." -f $scan.Summary.HostsAccessDenied) 'Warning'
    }
    $scan
}

function New-SQLMapHostStub {
    # Host result for hosts that never returned one (timeout, cancel, runspace failure).
    param($Target, [string]$Status, [string]$Detail)
    [pscustomobject][ordered]@{
        ComputerName = $Target.ShortName; DnsName = $null; IPAddress = $Target.IPAddress
        Sources = @($Target.Sources); AdOperatingSystem = $Target.OperatingSystem
        Status = $Status; StatusDetail = $Detail; IsLocal = $false; Reachable = $null; PingOK = $null
        OpenPorts = @(); Probes = [ordered]@{}; ProbeMessages = [ordered]@{}; HostInfo = $null; Services = @()
        SPNs = @($Target.SPNs); Instances = @(); InstanceCount = 0; InstanceTypes = $null; EngineCount = 0
        ScanStart = $null; DurationMs = $null
        Log = @([pscustomobject]@{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'); Level = 'Warning'; ComputerName = $Target.ShortName; Message = $Detail })
    }
}

function Merge-SQLMapHostResult {
    # The same machine can be reached through different names/IPs (AD name + IP range, DNS aliases,
    # 127.0.0.1...). Keep one result per address, preferring a name-based target over an IP target.
    param([object[]]$Hosts)
    $groups = [ordered]@{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($h in $Hosts) {
        $key = if ($h.IsLocal) { '#local' } elseif ($h.IPAddress -and $h.Reachable) { [string]$h.IPAddress } else { $null }
        if (-not $key) { $out.Add($h); continue }
        if (-not $groups.Contains($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($h)
    }
    foreach ($g in $groups.Values) {
        if ($g.Count -eq 1) { $out.Add($g[0]); continue }
        $keep = $g | Sort-Object @{ e = { if ([string]$_.ComputerName -match '^\d{1,3}(\.\d{1,3}){3}$') { 1 } else { 0 } } },
                                 @{ e = { if ($_.Sources -contains 'IPRange') { 1 } else { 0 } } },
                                 @{ e = { - $_.InstanceCount } } | Select-Object -First 1
        $others = @($g | Where-Object { $_ -ne $keep })
        $keep.Sources = @(@($g | ForEach-Object { $_.Sources }) | Select-Object -Unique)
        $aliases = @($others | ForEach-Object { $_.ComputerName } | Where-Object { $_ -ne $keep.ComputerName } | Select-Object -Unique)
        if ($aliases) {
            $keep.Log = @($keep.Log) + [pscustomobject]@{
                Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'); Level = 'Info'; ComputerName = $keep.ComputerName
                Message = "Also targeted as: $($aliases -join ', ') (same address, merged)"
            }
        }
        $out.Add($keep)
    }
    $out.ToArray()
}

function Get-SQLMapSummary {
    param($Scan)
    $hosts = @($Scan.Hosts)
    # Failover cluster instances show up on every node; count each SqlInstance once
    $unique = @($Scan.Instances | Sort-Object SqlInstance, ServiceType -Unique)
    $engines = @($unique | Where-Object { $_.ServiceType -eq 'Engine' })
    $byType = [ordered]@{}
    foreach ($t in 'Engine', 'SSAS', 'SSRS', 'PBIRS', 'SSIS') {
        $n = @($unique | Where-Object { $_.ServiceType -eq $t }).Count
        if ($n) { $byType[$t] = $n }
    }
    [pscustomobject][ordered]@{
        Targets           = $hosts.Count
        HostsReachable    = @($hosts | Where-Object { $_.Reachable }).Count
        HostsWithSql      = @($hosts | Where-Object { $_.Status -eq 'SQLFound' }).Count
        HostsNoSql        = @($hosts | Where-Object { $_.Status -eq 'NoSQLFound' }).Count
        HostsInconclusive = @($hosts | Where-Object { $_.Status -eq 'Inconclusive' }).Count
        HostsAccessDenied = @($hosts | Where-Object { $_.Status -eq 'Inconclusive' -and $_.Probes -and
                                (($_.Probes.Registry -eq 'AccessDenied') -or ($_.Probes.Service -eq 'AccessDenied')) }).Count
        HostsUnreachable  = @($hosts | Where-Object { $_.Status -in 'Unreachable', 'Unresolved' }).Count
        HostsFailed       = @($hosts | Where-Object { $_.Status -in 'Error', 'Timeout', 'Cancelled' }).Count
        Instances         = $unique.Count
        InstancesByType   = [pscustomobject]$byType
        Engines           = $engines.Count
        EnginesRunning    = @($engines | Where-Object { $_.IsRunning -eq $true }).Count
        EnginesOutOfSupport = @($engines | Where-Object { $_.SupportStatus -eq 'Out of support' }).Count
        EnginesBehindLatest = @($engines | Where-Object { $_.PatchStatus -in 'Behind', 'Security update missing' }).Count
        EnginesMissingSecurityUpdate = @($engines | Where-Object { $_.PatchStatus -eq 'Security update missing' }).Count
    }
}
