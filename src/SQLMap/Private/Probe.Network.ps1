# Network probes: DNS, ICMP, TCP connect, SQL Server Browser (UDP 1434).

function Resolve-SQLMapHost {
    param([string]$ComputerName, [string]$IPAddressHint, [int]$TimeoutMs = 2000)
    $r = [ordered]@{ Status = 'Failed'; DnsName = $null; IPAddresses = @(); Message = $null }
    $ip = $null
    $isIp = [System.Net.IPAddress]::TryParse($ComputerName, [ref]$ip)
    try {
        $task = [System.Net.Dns]::GetHostEntryAsync($ComputerName)
        if ($task.Wait($TimeoutMs)) {
            $entry = $task.Result
            $r.DnsName = $entry.HostName
            $r.IPAddresses = @($entry.AddressList |
                Sort-Object { if ($_.AddressFamily -eq 'InterNetwork') { 0 } else { 1 } } |
                Where-Object { -not $_.IsIPv6LinkLocal } |
                ForEach-Object { $_.ToString() })
            $r.Status = 'OK'
        }
        else { $r.Status = 'Timeout'; $r.Message = "DNS lookup timed out after $TimeoutMs ms" }
    }
    catch {
        $r.Message = Get-SQLMapErrorMessage $_
    }
    if ($isIp -and -not $r.IPAddresses) {
        # Reverse lookup failed but we still have a usable address
        $r.IPAddresses = @($ComputerName)
        $r.Status = 'NoReverse'
    }
    if (-not $r.IPAddresses -and $IPAddressHint) { $r.IPAddresses = @($IPAddressHint) }
    $r
}

function Test-SQLMapPing {
    param([string]$Address, [int]$TimeoutMs = 1000)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try { ($ping.Send($Address, $TimeoutMs)).Status -eq [System.Net.NetworkInformation.IPStatus]::Success }
    catch { $false }
    finally { $ping.Dispose() }
}

function Test-SQLMapTcpPort {
    # Connects to all ports concurrently; returns the list of open ports.
    param([string]$Address, [int[]]$Port, [int]$TimeoutMs = 1500)
    $pending = foreach ($p in ($Port | Select-Object -Unique)) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            [pscustomobject]@{ Port = $p; Client = $client; Async = $client.BeginConnect($Address, $p, $null, $null) }
        }
        catch {
            $client.Close()
            [pscustomobject]@{ Port = $p; Client = $null; Async = $null }
        }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $open = New-Object System.Collections.Generic.List[int]
    foreach ($item in $pending) {
        if (-not $item.Async) { continue }
        try {
            $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($item.Async.AsyncWaitHandle.WaitOne($remaining)) {
                try { $item.Client.EndConnect($item.Async); $open.Add($item.Port) } catch { }
            }
        }
        finally { $item.Client.Close() }
    }
    @($open | Sort-Object)
}

function Get-SQLMapTdsPrelogin {
    # TDS PRELOGIN handshake (the first packet of every SQL Server connection, before TLS and before any login).
    # The server answers with its exact build (major.minor.build), so this works when the login fails, when
    # encryption is forced, and with no credentials at all. It also proves a SQL Server is listening on the port.
    # Returns @{ Status = OK|Closed|NotSql|Timeout|Error; Version = '15.0.4365'; Encryption; Message }
    param([string]$Address, [int]$Port, [int]$TimeoutMs = 1500)
    $r = [ordered]@{ Status = 'Error'; Version = $null; Encryption = $null; Message = $null }
    # Header: type 0x12 (PRELOGIN), status 0x01 (EOM), length 26 (big-endian), SPID 0, packet 0, window 0
    # Options: VERSION (0x00) at offset 11, length 6; ENCRYPTION (0x01) at offset 17, length 1; terminator 0xFF
    # Data: client version 0.0.0.0 + ENCRYPT_NOT_SUP (0x02)
    [byte[]]$packet = 0x12, 0x01, 0x00, 0x1A, 0x00, 0x00, 0x00, 0x00,
                      0x00, 0x00, 0x0B, 0x00, 0x06,
                      0x01, 0x00, 0x11, 0x00, 0x01,
                      0xFF,
                      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                      0x02
    $client = New-Object System.Net.Sockets.TcpClient
    $connected = $false
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { $r.Status = 'Timeout'; $r.Message = 'TCP connect timed out'; return [pscustomobject]$r }
        try { $client.EndConnect($async) } catch { $r.Status = 'Closed'; $r.Message = Get-SQLMapErrorMessage $_; return [pscustomobject]$r }
        $connected = $true
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs; $stream.WriteTimeout = $TimeoutMs
        $stream.Write($packet, 0, $packet.Length)

        # Read the 8-byte header, then the rest of the packet
        $buf = New-Object byte[] 4096
        $read = 0
        while ($read -lt 8) { $n = $stream.Read($buf, $read, 8 - $read); if ($n -le 0) { break }; $read += $n }
        if ($read -lt 8 -or $buf[0] -ne 0x04) { $r.Status = 'NotSql'; $r.Message = 'No TDS reply on this port'; return [pscustomobject]$r }
        $total = [Math]::Min(($buf[2] * 256) + $buf[3], $buf.Length)
        while ($read -lt $total) { $n = $stream.Read($buf, $read, $total - $read); if ($n -le 0) { break }; $read += $n }

        # Walk the option table (token, offset BE, length BE), offsets relative to the end of the header
        $i = 8
        while ($i + 4 -lt $read -and $buf[$i] -ne 0xFF) {
            $token = $buf[$i]
            $off = 8 + ($buf[$i + 1] * 256) + $buf[$i + 2]
            $len = ($buf[$i + 3] * 256) + $buf[$i + 4]
            if ($token -eq 0x00 -and $len -ge 4 -and $off + 3 -lt $read) {
                $r.Version = '{0}.{1}.{2}' -f $buf[$off], $buf[$off + 1], (($buf[$off + 2] * 256) + $buf[$off + 3])
            }
            elseif ($token -eq 0x01 -and $len -ge 1 -and $off -lt $read) {
                $r.Encryption = @{ 0 = 'Off'; 1 = 'On'; 2 = 'NotSupported'; 3 = 'Required' }[[int]$buf[$off]]
            }
            $i += 5
        }
        if ($r.Version) { $r.Status = 'OK' } else { $r.Status = 'NotSql'; $r.Message = 'TDS reply without a version' }
    }
    catch {
        # Connected but no valid TDS answer (reset, silence, another protocol): not a SQL Server endpoint
        $r.Status = if ($connected) { 'NotSql' } else { 'Error' }
        $r.Message = Get-SQLMapErrorMessage $_
    }
    finally { $client.Close() }
    [pscustomobject]$r
}

function Get-SQLMapBrowserInstance {
    # Unicast SSRP CLNT_UCAST_EX (0x03) to UDP 1434.
    param([string]$Address, [int]$TimeoutMs = 1500)
    $r = [ordered]@{ Status = 'NoReply'; Instances = @(); Message = $null }
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Address, 1434)
        [void]$udp.Send([byte[]](0x03), 1)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $udp.Receive([ref]$remote)
        $r.Instances = @(ConvertFrom-SQLMapBrowserResponse $bytes)
        $r.Status = 'OK'
    }
    catch {
        $msg = Get-SQLMapErrorMessage $_
        # ICMP port unreachable surfaces as "connection reset" on a connected UDP socket
        if ($msg -match 'forcibly closed|reset|for.ada') { $r.Status = 'Closed' } else { $r.Status = 'NoReply' }
        $r.Message = $msg
    }
    finally { $udp.Close() }
    $r
}
