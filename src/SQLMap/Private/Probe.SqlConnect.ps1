# Optional SQL connection probe. Read-only queries; works from SQL Server 2005 onwards.

$script:SqlConnectQuery = @'
SET NOCOUNT ON;
SELECT
    @@SERVERNAME                                                  AS ServerName,
    CONVERT(nvarchar(128), SERVERPROPERTY('MachineName'))         AS MachineName,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'))      AS ProductVersion,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel'))        AS ProductLevel,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateLevel'))  AS ProductUpdateLevel,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateReference')) AS ProductUpdateReference,
    CONVERT(nvarchar(128), SERVERPROPERTY('Edition'))             AS Edition,
    CONVERT(int, SERVERPROPERTY('EngineEdition'))                 AS EngineEdition,
    CONVERT(int, SERVERPROPERTY('IsClustered'))                   AS IsClustered,
    CONVERT(int, SERVERPROPERTY('IsHadrEnabled'))                 AS IsHadrEnabled,
    CONVERT(nvarchar(128), SERVERPROPERTY('Collation'))           AS Collation,
    (SELECT COUNT(*) FROM sys.databases)                          AS DatabaseCount,
    (SELECT COUNT(*) FROM sys.databases WHERE name = N'SSISDB')   AS HasSsisCatalog,
    (SELECT CONVERT(decimal(18, 2), SUM(CASE WHEN type = 0 THEN CONVERT(bigint, size) ELSE 0 END) * 8 / 1048576.0) FROM sys.master_files) AS DataSizeGB,
    (SELECT CONVERT(decimal(18, 2), SUM(CASE WHEN type = 1 THEN CONVERT(bigint, size) ELSE 0 END) * 8 / 1048576.0) FROM sys.master_files) AS LogSizeGB,
    (SELECT CONVERT(int, value_in_use) FROM sys.configurations WHERE name = 'max server memory (MB)') AS MaxServerMemoryMB;
'@

# Needs VIEW SERVER STATE; executed separately so the main query still works without it
$script:SqlConnectSysInfoQuery = 'SELECT cpu_count AS CpuCount, sqlserver_start_time AS StartTime FROM sys.dm_os_sys_info;'

# Service accounts of this instance (engine and SQL Agent), SQL Server 2008 R2 SP1 and later. Needs VIEW SERVER STATE.
# Gives the account without Windows admin rights on the host. Database engine rows are 'SQL Server (INSTANCE)'.
$script:SqlConnectServicesQuery = @'
SELECT servicename, service_account FROM sys.dm_server_services
WHERE servicename LIKE N'SQL Server (%' OR servicename LIKE N'SQL Server Agent (%';
'@

# Security checks (read-only). Visibility depends on the scan login: sysadmin sees everything; other logins see
# their own login, the system logins and fixed roles only (ScanLoginSysadmin tells which case applies).
$script:SqlSecurityQuery = @'
SELECT CONVERT(int, SERVERPROPERTY('IsIntegratedSecurityOnly')) AS IntegratedOnly,
       (SELECT name FROM sys.server_principals WHERE principal_id = 1) AS SaName,
       (SELECT CONVERT(int, is_disabled) FROM sys.server_principals WHERE principal_id = 1) AS SaDisabled,
       IS_SRVROLEMEMBER('sysadmin') AS ScanLoginSysadmin;
'@
$script:SqlSysadminQuery = @'
SELECT p.name, p.type_desc, CONVERT(int, p.is_disabled) AS is_disabled
FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals p ON p.principal_id = rm.member_principal_id
WHERE r.name = N'sysadmin';
'@
$script:SqlLoginQuery = "SELECT name, type_desc, CONVERT(int, is_disabled) AS is_disabled FROM sys.server_principals WHERE type IN ('U', 'G') AND UPPER(name) IN (UPPER(@a1), UPPER(@a2));"
$script:SqlLinkedServersQuery = @'
SELECT s.server_id, s.name, s.product, s.provider, s.data_source, CONVERT(int, s.is_rpc_out_enabled) AS rpc_out
FROM sys.servers s WHERE s.is_linked = 1;
'@
$script:SqlLinkedLoginsQuery = @'
SELECT ll.server_id, ISNULL(p.name, N'(all logins)') AS local_login, CONVERT(int, ll.uses_self_credential) AS self, ll.remote_name
FROM sys.linked_logins ll LEFT JOIN sys.server_principals p ON p.principal_id = ll.local_principal_id;
'@
$script:SqlAgReplicasQuery = @'
SELECT ag.name AS ag_name, ar.replica_server_name, ar.availability_mode_desc, ar.failover_mode_desc, rs.role_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id;
'@
$script:SqlAgListenersQuery = 'SELECT ag.name AS ag_name, l.dns_name, l.port FROM sys.availability_group_listeners l JOIN sys.availability_groups ag ON ag.group_id = l.group_id;'

function Invoke-SQLMapSqlQuery {
    # Rows of a query as objects
    param($Connection, [string]$Query, [hashtable]$Parameters = @{})
    $cmd = $Connection.CreateCommand()
    $cmd.CommandTimeout = 30
    $cmd.CommandText = $Query
    foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $(if ($null -eq $Parameters[$k]) { [DBNull]::Value } else { $Parameters[$k] })) }
    $reader = $cmd.ExecuteReader()
    try {
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($c = 0; $c -lt $reader.FieldCount; $c++) { $v = $reader.GetValue($c); $row[$reader.GetName($c)] = if ($v -is [DBNull]) { $null } else { $v } }
            [pscustomobject]$row
        }
    }
    finally { $reader.Close() }
}

function ConvertTo-SQLMapSqlLoginName {
    # How a service account appears as a SQL Server login
    param([string]$Account, [string]$MachineName)
    if (-not $Account) { return $null }
    $a = $Account.Trim()
    if ($a -match '^(\.\\)?LocalSystem$') { return 'NT AUTHORITY\SYSTEM' }
    if ($a -match '^(NT AUTHORITY\\)?NetworkService$|^NT AUTHORITY\\NETWORK ?SERVICE$') { return 'NT AUTHORITY\NETWORK SERVICE' }
    if ($a -match '^\.\\(.+)$' -and $MachineName) { return "$MachineName\$($Matches[1])" }
    if ($a -match '@') { return $null }   # UPN: no login name to compare with
    $a
}

function Get-SQLMapSqlSecurity {
    # Authentication mode, sa, sysadmin members, logins of the service / Agent accounts, linked servers, AGs.
    # Fills $Result in place; each part is independent so a missing permission only loses that part.
    param($Connection, $Result, [hashtable]$Context, [string]$DataSource, [string]$ServiceAccount, [string]$AgentAccount)
    try {
        $s = @(Invoke-SQLMapSqlQuery $Connection $script:SqlSecurityQuery)[0]
        $Result.AuthenticationMode = if ($s.IntegratedOnly -eq 1) { 'Windows' } else { 'Mixed (Windows and SQL logins)' }
        $Result.ScanLoginSysadmin = ($s.ScanLoginSysadmin -eq 1)
        if ($s.SaName) {
            $Result.SaLogin = ("$(if ($s.SaName -eq 'sa') { 'sa' } else { "sa renamed to '$($s.SaName)'" }), $(if ($s.SaDisabled -eq 1) { 'disabled' } else { 'enabled' })")
        }
    }
    catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: security settings not readable: $(Get-SQLMapErrorMessage $_)" }

    $sysadmins = $null
    try {
        $sysadmins = @(Invoke-SQLMapSqlQuery $Connection $script:SqlSysadminQuery)
        $Result.SysadminLogins = @($sysadmins | ForEach-Object { [string]$_.name })
    }
    catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: sysadmin members not readable: $(Get-SQLMapErrorMessage $_)" }

    # Logins of the service and Agent accounts (direct logins; group logins are resolved after the AD review)
    $svcLogin = ConvertTo-SQLMapSqlLoginName $ServiceAccount $Result.MachineName
    $agtLogin = ConvertTo-SQLMapSqlLoginName $AgentAccount $Result.MachineName
    if ($svcLogin -or $agtLogin) {
        try {
            $rows = @(Invoke-SQLMapSqlQuery $Connection $script:SqlLoginQuery @{ a1 = $svcLogin; a2 = $agtLogin })
            foreach ($pair in @(@('ServiceAccountLogin', $svcLogin), @('AgentAccountLogin', $agtLogin))) {
                if (-not $pair[1]) { continue }
                $row = $rows | Where-Object { ([string]$_.name).ToUpperInvariant() -eq $pair[1].ToUpperInvariant() } | Select-Object -First 1
                $isSa = $sysadmins -and (@($sysadmins | Where-Object { ([string]$_.name).ToUpperInvariant() -eq $pair[1].ToUpperInvariant() }).Count -gt 0)
                $Result[$pair[0]] = if ($row -and $isSa) { 'sysadmin' + $(if ($row.is_disabled -eq 1) { ' (login disabled)' } else { '' }) + $(if ($pair[1] -like 'NT SERVICE\*') { ' (service SID login, SQL Server default)' } else { '' }) }
                    elseif ($row) { 'Login, not sysadmin' + $(if ($row.is_disabled -eq 1) { ' (disabled)' } else { '' }) }
                    elseif ($Result.ScanLoginSysadmin) { 'No login' }
                    else { 'Not visible to the scan login' }
            }
        }
        catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: service account logins not readable: $(Get-SQLMapErrorMessage $_)" }
    }

    # Linked servers and how logins are mapped on them
    try {
        $servers = @(Invoke-SQLMapSqlQuery $Connection $script:SqlLinkedServersQuery)
        $logins = @()
        if ($servers.Count) { try { $logins = @(Invoke-SQLMapSqlQuery $Connection $script:SqlLinkedLoginsQuery) } catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: linked server logins not readable: $(Get-SQLMapErrorMessage $_)" } }
        $Result.LinkedServers = @(foreach ($sv in $servers) {
            $maps = @(foreach ($l in @($logins | Where-Object { $_.server_id -eq $sv.server_id })) {
                if ($l.self -eq 1) { "$($l.local_login) as itself" }
                elseif ($l.remote_name) { "$($l.local_login) as remote login '$($l.remote_name)'" }
                else { "$($l.local_login): no remote login" }
            })
            $target = (@($sv.data_source, $(if ($sv.provider) { "provider $($sv.provider)" })) | Where-Object { $_ }) -join ', '
            "$($sv.name) -> $target" + $(if ($maps.Count) { "; logins: $($maps -join '; ')" } else { '' }) + $(if ($sv.rpc_out -eq 1) { '; RPC out on' } else { '' })
        })
    }
    catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: linked servers not readable: $(Get-SQLMapErrorMessage $_)" }

    # Availability groups: replicas (with role when visible) and listeners
    if ($Result.IsHadrEnabled -eq 1) {
        try {
            $reps = @(Invoke-SQLMapSqlQuery $Connection $script:SqlAgReplicasQuery)
            $lsn = @(); try { $lsn = @(Invoke-SQLMapSqlQuery $Connection $script:SqlAgListenersQuery) } catch { }
            $Result.AvailabilityGroups = @(foreach ($g in ($reps | Group-Object ag_name)) {
                $r = @($g.Group | ForEach-Object { "$($_.replica_server_name) (" + ((@($_.role_desc, ($_.availability_mode_desc -replace '_COMMIT', '' -replace 'SYNCHRONOUS', 'sync' -replace 'ASYNCHRONOUS', 'async').ToLowerInvariant(), ([string]$_.failover_mode_desc).ToLowerInvariant() + ' failover') | Where-Object { $_ }) -join ', ') + ')' })
                $l = @($lsn | Where-Object { $_.ag_name -eq $g.Name } | ForEach-Object { "$($_.dns_name):$($_.port)" })
                "$($g.Name): replicas $($r -join ', ')" + $(if ($l.Count) { "; listener $($l -join ', ')" } else { '; no listener' })
            })
        }
        catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: availability groups not readable: $(Get-SQLMapErrorMessage $_)" }
    }
}

function Invoke-SQLMapSqlConnect {
    param(
        [hashtable]$Context,
        [string]$DataSource,
        [pscredential]$SqlCredential,
        [int]$TimeoutSec = 5,
        # Accounts already known from the Windows services (sys.dm_server_services fills them otherwise)
        [string]$ServiceAccount,
        [string]$AgentAccount
    )
    $r = [ordered]@{
        Status = 'Error'; DataSource = $DataSource; Message = $null
        ServerName = $null; MachineName = $null; ProductVersion = $null; ProductLevel = $null
        ProductUpdateLevel = $null; ProductUpdateReference = $null; Edition = $null; EngineEdition = $null
        IsClustered = $null; IsHadrEnabled = $null; Collation = $null; DatabaseCount = $null; HasSsisCatalog = $null
        DataSizeGB = $null; LogSizeGB = $null; MaxServerMemoryMB = $null; CpuCount = $null; StartTime = $null
        ServiceAccount = $null; AgentServiceAccount = $null
        AuthenticationMode = $null; SaLogin = $null; ScanLoginSysadmin = $null; SysadminLogins = $null
        ServiceAccountLogin = $null; AgentAccountLogin = $null; LinkedServers = $null; AvailabilityGroups = $null
    }
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $csb['Data Source']        = $DataSource
    $csb['Initial Catalog']    = 'master'
    $csb['Connect Timeout']    = $TimeoutSec
    $csb['Application Name']   = 'SQLMap'
    $csb['Pooling']            = $false
    $csb['TrustServerCertificate'] = $true
    if (-not $SqlCredential) { $csb['Integrated Security'] = $true }

    $conn = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
    if ($SqlCredential) {
        $securePassword = $SqlCredential.Password.Copy()
        $securePassword.MakeReadOnly()
        $conn.Credential = New-Object System.Data.SqlClient.SqlCredential($SqlCredential.UserName, $securePassword)
    }
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 30
        $cmd.CommandText = $script:SqlConnectQuery
        $reader = $cmd.ExecuteReader()
        try {
            if ($reader.Read()) {
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $v = $reader.GetValue($i)
                    $r[$reader.GetName($i)] = if ($v -is [DBNull]) { $null } else { $v }
                }
            }
        }
        finally { $reader.Close() }

        try {
            $cmd.CommandText = $script:SqlConnectSysInfoQuery
            $reader = $cmd.ExecuteReader()
            try {
                if ($reader.Read()) {
                    $r.CpuCount  = $reader.GetValue(0)
                    $r.StartTime = ConvertTo-SQLMapIsoDate $reader.GetValue(1)
                }
            }
            finally { $reader.Close() }
        }
        catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: CPU count and start time not available (sys.dm_os_sys_info needs VIEW SERVER STATE)" }

        try {
            $cmd.CommandText = $script:SqlConnectServicesQuery
            $reader = $cmd.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $name = [string]$reader.GetValue(0)
                    $acct = if ($reader.IsDBNull(1)) { $null } else { [string]$reader.GetValue(1) }
                    if ($name -like 'SQL Server Agent (*') { $r.AgentServiceAccount = $acct } else { $r.ServiceAccount = $acct }
                }
            }
            finally { $reader.Close() }
        }
        catch { Add-SQLMapLog $Context "SqlConnect ${DataSource}: service account not available (sys.dm_server_services needs VIEW SERVER STATE and SQL Server 2008 R2 SP1 or later)" }

        Get-SQLMapSqlSecurity -Connection $conn -Result $r -Context $Context -DataSource $DataSource `
            -ServiceAccount $(if ($ServiceAccount) { $ServiceAccount } else { $r.ServiceAccount }) `
            -AgentAccount $(if ($AgentAccount) { $AgentAccount } else { $r.AgentServiceAccount })

        if ($null -ne $r.DataSizeGB) { $r.DataSizeGB = [double]$r.DataSizeGB }
        if ($null -ne $r.LogSizeGB)  { $r.LogSizeGB  = [double]$r.LogSizeGB }
        $r.Status = 'OK'
        Add-SQLMapLog $Context "SqlConnect ${DataSource}: connected ($($r.ProductVersion))"
    }
    catch {
        $r.Status  = Get-SQLMapErrorKind $_
        $r.Message = Get-SQLMapErrorMessage $_
        Add-SQLMapLog $Context "SqlConnect ${DataSource}: $($r.Message)" -Level Warning
    }
    finally { $conn.Dispose() }
    [pscustomobject]$r
}
