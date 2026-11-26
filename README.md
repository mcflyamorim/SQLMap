# SQLMap

Discovers SQL Server services on a network and produces an interactive HTML report plus JSON/CSV exports:

- **Instances:** Database Engine, Analysis Services (SSAS), Reporting Services (SSRS), Power BI Report Server,
  Integration Services (SSIS)
- **Engine components:** SQL Agent, Full-Text, PolyBase, ML Services (Launchpad), SSISDB catalog (with `-SqlConnect`)
- **SSIS components:** Scale Out Master / Worker
- Windows Internal Database is detected and flagged (it is not a licensed SQL Server)

Rewrite of the old `MAP_SQLServices` script: no dbatools or RSAT dependency, parallel scanning, credential support
and a self-contained offline report.

> The output contains client infrastructure data: keep it out of source control (`Output/` is git-ignored)
> and share it as confidential.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ on Windows
- Nothing to install. AD discovery uses ADSI, so the RSAT ActiveDirectory module is **not** needed.
- If the files were downloaded (zip/e-mail), unblock them first:
  `Get-ChildItem -Recurse | Unblock-File`

## Windows UI

Double-click **`SQLMap.cmd`** (or run `powershell.exe -STA -File .\SQLMap.ps1`). As in SQLSecReview, the console shows each
startup step with the seconds since launch and the build reference date. Keep it open while SQLMap runs: closing it
closes the application.

- **Targets / Options / Credentials / Output** tabs on the left map 1:1 to the CLI parameters below.
- Results stream into the **Instances** and **Hosts** grids while the scan runs; double-click a row for details
  (probes, services, scan log). **Cancel** stops the scan and keeps what was already found.
- Each scan is saved to its own output folder; **Load scan (JSON)** reopens an earlier one.
- Dark theme by default; **Light theme** / **Dark theme** (bottom right) switches it, and the choice is remembered.
- Settings are remembered in `%APPDATA%\SQLMap\ui-settings.json` (credentials never are: only user names).
- **SQL connection** is on by default (Windows authentication unless a SQL login is set). The HTML report is not
  opened automatically unless **Open the HTML report when the scan finishes** is checked.

`SQLMap.cmd` starts PowerShell with `-ExecutionPolicy Bypass` for that process only, because the scripts are not
signed yet.

## Command line

```powershell
# Local computer
.\SQLMap.Cli.ps1 -OpenReport

# All enabled Windows Server accounts in the current domain + every host with a MSSQLSvc SPN
.\SQLMap.Cli.ps1 -ActiveDirectory -SPN -OpenReport

# Subnets / ranges, extra SQL ports, more threads
.\SQLMap.Cli.ps1 -IpRange 10.0.1.0/24, 10.0.2.10-60 -TcpPort 1433,14330 -Throttle 64

# Server list + SQL connection details, with alternate Windows credentials for registry/WMI
.\SQLMap.Cli.ps1 -InputFile .\servers.txt -SqlConnect -Credential (Get-Credential CONTOSO\dbaadmin)
```

Each run creates `Output\SQLMap_yyyyMMdd_HHmmss\` containing:

| File | Content |
|---|---|
| `SQLMap.html` | Interactive report (single file, works offline) |
| `SQLMap.json` | Full scan, re-loadable with `Import-SQLMapScan` |
| `SQLMap_Instances.csv` | One row per instance |
| `SQLMap_Hosts.csv` | One row per scanned host, with probe results |
| `SQLMap.log` | Scan log |

## Discovery sources (combinable)

| Parameter | Source |
|---|---|
| `-ComputerName` | Explicit names; `srv`, `srv\inst`, `srv,1433` are accepted |
| `-InputFile` | `.txt` (one per line, `#` comments) or `.csv` with a `ComputerName`/`Name`/`Server`/`Host`/`SqlInstance` column |
| `-ActiveDirectory` | Enabled computer accounts. Servers only unless `-IncludeWorkstations`; accounts with no logon in `-ActiveWithinDays` (90) are skipped; failover-cluster virtual names are skipped (their nodes report them). Narrow with `-NameFilter 'SQL*'` or `-SearchBase 'OU=...'` |
| `-SPN` | Every `MSSQLSvc/*` SPN in the domain (computer and service accounts) |
| `-IpRange` | `10.0.0.0/24`, `10.0.0.1-10.0.0.50`, `10.0.0.1-50`, single IPs (max 65,536 addresses) |
| `-Broadcast` | SQL Browser UDP broadcast on the local subnet (what SSMS "Browse for servers" uses) |

`-Domain` and `-Credential` also apply to AD/SPN queries (e.g. scanning another domain).

## Probes

| Probe | What it does | Needs |
|---|---|---|
| `Ping` | ICMP echo. A failure does not stop the scan | - |
| `Tcp` | TCP connect to `-TcpPort` (default 1433) | - |
| `Browser` | SQL Server Browser query (UDP 1434): instance names and ports | SQL Browser running |
| `Registry` | Installed instances (incl. SSIS), edition, build, cluster, TCP port, Full-Text/PolyBase, last-running heartbeat | Remote Registry (current user) or WMI (`-Credential`) |
| `Service` | Windows services (state, start mode, account) + OS, cores, memory, virtualization | WMI/CIM over WinRM or DCOM, usually local admin |
| TDS handshake | Part of `Tcp`. Sends the SQL Server pre-login packet to each engine port whose build is not known from the registry. The server answers with its exact build before any login, so it works when the login fails or encryption is forced. It also proves the port is a SQL Server | TCP access to the instance port |
| `SqlConnect` | Read-only queries: exact build/CU, databases, sizes, collation, HADR, SSISDB catalog (`-SqlConnect`) | SQL login (Windows auth or `-SqlCredential`) |

SSIS is detected from `<version>\DTS\Setup` only when `FeatureList` contains `SQL_DTS_Full`, because SSMS/SSDT
create `DTS` keys too. It appears as one row per version, e.g. `SRV01 (SSIS130)`.

Management ports 135, 445 and 5985 are always checked, so probes that cannot work are skipped instead of waiting for
timeouts.

- **SPN ports:** ports in a host's `MSSQLSvc` SPNs (`MSSQLSvc/srv:56615`) are probed with the `-TcpPort` list. SPNs can
  be read without admin rights, so with `-SPN` named instances are found on hosts whose registry and services are
  closed to the scan account.
- **SQL Browser versions** are the base release (e.g. `15.0.2000.5` on a CU32 server). They name the product but are
  never used for the patch level. That comes from the registry, the TDS handshake or a SQL connection, and
  `VersionSource` says which.
- **Access denied:** hosts where the registry and services could not be read show *Access denied* and are counted at
  the end of the scan. The scan account must be local administrator on the targets (Credentials tab or `-Credential`).
- **Kerberos errors:** "Cannot generate SSPI context" points to a missing, duplicate or wrongly registered SPN. It is
  noted on the instance, and the connection is retried by IP address (NTLM).
- **Service account:** read from the first source that works. The report marks the column `(SQL)` or `(AD)` when the
  account came from one of the last two.
  1. Windows services (needs local admin).
  2. The SQL connection, using `sys.dm_server_services` (needs `VIEW SERVER STATE`, SQL Server 2008 R2 SP1+). This
     also gives the SQL Agent account.
  3. The AD account holding the instance's `MSSQLSvc` SPN, with `-SPN` (any domain user can read it). An SPN on the
     computer account means a built-in account (NT Service, LocalSystem or Network Service).
- **SPN findings:** with `-SPN`, an instance note flags an SPN registered on two accounts (duplicate) or on a
  different account than the one the service runs as. Both break Kerberos. Every instance gets a **confidence** level: *High* (registry, services or SQL connection), *Medium*
(Browser, or SPN + open port), *Low* (only an SPN or an open port).

Host statuses: `SQLFound`, `NoSQLFound`, `Inconclusive` (reachable, but neither registry nor services could be
read: SQL may still be there), `Unreachable`, `Unresolved`, `Timeout`, `Error`, `Cancelled`. The report's
**Issues** tab lists every host that could not be fully checked and why.

## Using the module directly

```powershell
Import-Module .\src\SQLMap\SQLMap.psd1

$scan = Invoke-SQLMapScan -ActiveDirectory -SqlConnect -Verbose
$scan.Instances | Where-Object SupportStatus -eq 'Out of support' | Format-Table SqlInstance, ProductName, Version
$scan | Export-SQLMapReport -Path .\Output\Contoso

# Single host
Invoke-SQLMapComputerScan -Target SRV01 -Probe Ping, Tcp, Registry, Service

# Re-render an old scan with the current report template
Import-SQLMapScan .\Output\Contoso\SQLMap.json | Export-SQLMapReport -Path .\Output\Contoso -Format Html
```

`Invoke-SQLMapScan -State <synchronized hashtable>` exposes progress counters, a log queue, a finished-host queue
and a `CancelRequested` flag. This is how the WinForms UI follows and cancels a scan.

## Project layout

```
SQLMap.cmd                     double-click launcher for the UI (console shows the startup steps)
SQLMap.ps1                     UI entry point (relaunches itself in STA if needed)
SQLMap.Cli.ps1                 command line entry point
src/SQLMapUI/SQLMap.UI.ps1     WinForms UI (scan runs in a background runspace; dark/light themes)
assets/SQLMap.ico|.png|.svg    app icon (window, report favicon/logo)
tools/New-SQLMapIcon.ps1       regenerates the icon files
src/SQLMap/
  SQLMap.psd1 / .psm1          module
  Public/                      exported functions
  Private/
    Discovery.ps1              AD, SPN, IP range, broadcast, file
    Probe.Network.ps1          DNS, ping, TCP, SQL Browser
    Probe.Registry.ps1         Remote Registry / WMI StdRegProv readers
    Probe.Cim.ps1              services, OS/hardware
    Probe.SqlConnect.ps1       SQL queries
    Merge.ps1                  evidence merge, confidence, lifecycle
    Common.ps1                 helpers
  Data/SqlProducts.json        versions + Microsoft lifecycle dates (review periodically)
  Templates/report.html        report template (data is embedded at export time)
```

## Patch level (latest update)

Each Engine, SSAS and SSIS instance (SQL Server 2008 to 2025) is compared with the official build lists on Microsoft
Learn, with the same reference format and logic SQLSecReview uses (check SQL0147):

| Versions | Source |
|---|---|
| 2017-2025 | `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-<year>/build-versions` (same pages and parsing as SQLSecReview) |
| 2008-2016 | "SQL Server complete version list tables" on `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates` |

- **Servicing branch:** every service pack has a **CU** branch and a **GDR** branch.
  - The CU branch holds cumulative updates, `CUnn + GDR`, QFE security updates and the 2016 SP3 Azure Connect Pack.
  - The GDR branch holds security-only updates.
  - Branches are named `CU` / `RTM-GDR` for 2017+ (which have no service packs) and `SP3-CU`, `SP4-GDR`, ... for 2008-2016.
  - An unlisted build is placed on the CU branch when it is at or above the first CU build of its service pack.
- **Patch status**, against the latest release of the same branch on the **newest service pack**:
  - *Latest*.
  - *Behind*, with the number of service packs plus releases still to install.
  - *Security update missing*: below the latest security release of that branch. This includes any instance on an
    older service pack, e.g. SQL Server 2012 SP3, whose target is SP4 plus the latest GDR.
  - *Newer than reference*: the build is newer than the file, so refresh it.
  - *Not covered*: SQL Server 2005 and older.
- **Exception:** on 2008 / 2008 R2 the last QFE (2015) is below the later security GDRs (2018, 2023), so instances on
  the QFE side are pointed to the latest GDR.

The reference is stored in `src/SQLMap/Data/sql-update-reference.json`, in the same format as SQLSecReview's
`rules/sql-update-reference.json`. **Scans never go to the internet.** Refresh it before visiting a client:

```powershell
Import-Module .\src\SQLMap\SQLMap.psd1
Update-SQLMapBuildReference                      # reads the Microsoft Learn pages (2008-2025)
Update-SQLMapBuildReference -Path ..\SQLSecReview\rules\sql-update-reference.json   # or import an existing file
```

Importing SQLSecReview's file, which covers only 2017-2025, keeps the 2008-2016 rows already in SQLMap's file.

The reference is considered current for 30 days (`MaxAgeDays`). The report shows the retrieval date, and warns when it was
older than that at scan time. SSRS and Power BI Report Server ship on their own release track and are not compared.

## Notes

- Versions are shown as SQL Server reports them (`SERVERPROPERTY('ProductVersion')`): the registry `PatchLevel`
  stores the service pack in the minor number (`13.3.7095.1`, `10.53.6000.34`), which SQLMap normalizes to
  `13.0.7095.1` / `10.50.6000.34`.
- Lifecycle dates live in `src/SQLMap/Data/SqlProducts.json`. SQL Server 2025 dates are not filled in yet, so
  2025 instances show *Supported (dates not set)*.
- Failover cluster instances appear once per node in the tables and are counted once (by `SqlInstance`) in
  the summary.
- The same machine reached through several names or IPs (AD name + IP range, DNS aliases) is merged into one host.
- The HTML report needs a modern browser (Edge, Chrome, Firefox). On older servers that only have IE11,
  copy the file to a workstation.
