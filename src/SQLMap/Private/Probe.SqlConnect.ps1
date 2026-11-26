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

function Invoke-SQLMapSqlConnect {
    param(
        [hashtable]$Context,
        [string]$DataSource,
        [pscredential]$SqlCredential,
        [int]$TimeoutSec = 5
    )
    $r = [ordered]@{
        Status = 'Error'; DataSource = $DataSource; Message = $null
        ServerName = $null; MachineName = $null; ProductVersion = $null; ProductLevel = $null
        ProductUpdateLevel = $null; ProductUpdateReference = $null; Edition = $null; EngineEdition = $null
        IsClustered = $null; IsHadrEnabled = $null; Collation = $null; DatabaseCount = $null; HasSsisCatalog = $null
        DataSizeGB = $null; LogSizeGB = $null; MaxServerMemoryMB = $null; CpuCount = $null; StartTime = $null
        ServiceAccount = $null; AgentServiceAccount = $null
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
