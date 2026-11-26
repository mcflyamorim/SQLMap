# SQLMap

Discovers SQL Server services on a network and produces an interactive HTML report plus JSON/CSV exports, from a
Windows UI or the command line.

**What it finds:**
- **Instances:** Database Engine, Analysis Services (SSAS), Reporting Services (SSRS), Power BI Report Server,
  Integration Services (SSIS).
- **Engine components:** SQL Agent, Full-Text, PolyBase, ML Services (Launchpad), SSISDB catalog.
- **SSIS components:** Scale Out Master / Worker.
- **Windows Internal Database:** detected and flagged, because it is not a licensed SQL Server.

**What it reports for each instance:**
- **Version and support:** product, edition, exact build, and Microsoft lifecycle status (mainstream, extended, out
  of support).
- **Patch level:** compared with the official Microsoft Learn build lists (2008-2025). It flags instances that are
  behind the latest update or missing a security update.
- **Accounts:** the service account and the SQL Agent account, even without admin rights on the host (from the SQL
  connection or from AD).
- **Kerberos problems:** duplicate SPNs, or SPNs on the wrong account.
- **With a SQL connection:**
  - databases, data/log sizes, collation, HADR and max server memory
  - whether the service and Agent accounts have logins and are sysadmin
  - linked servers and their login mappings, authentication mode, `sa` (enabled, renamed)
  - availability group replicas and listeners
- **Service account review in AD:** for each account running a SQL Server service, the checks below. Each account gets
  a risk level from *Critical* to *No findings*. See [Service account review](#service-account-review).
  - privileged groups (nested), `adminCount`
  - delegation
  - Kerberoasting exposure (SPNs, password age, RC4)
  - local admin rights on the scanned hosts

Rewrite of the old `MAP_SQLServices` script: no dbatools or RSAT dependency, parallel scanning, credential support
and a self-contained offline report.

> The output contains client infrastructure data and security findings (privileged service accounts, delegation,
> linked server mappings): keep it out of source control (`Output/` is git-ignored) and share it as confidential.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ on Windows.
- Nothing to install. AD discovery and the service account review use ADSI, so the RSAT ActiveDirectory module is
  **not** needed.
- AD discovery and the service account review need a domain-joined computer, or `-Domain` with `-Credential`. Any
  domain user can read what they use.
- If the files were downloaded (zip/e-mail), unblock them first: `Get-ChildItem -Recurse | Unblock-File`.

## Windows UI

Double-click **`SQLMap.cmd`**, or run `powershell.exe -STA -File .\SQLMap.ps1`.

**Starting:**
- A console shows each startup step with the seconds since launch, plus the build reference date, as in
  SQLSecReview.
- Keep the console open while SQLMap runs: closing it closes the application.
- `SQLMap.cmd` uses `-ExecutionPolicy Bypass` for that process only, because the scripts are not signed yet.

**Configuring a scan:**
- The **Targets / Options / Credentials / Output** tabs on the left map 1:1 to the command-line parameters.
- **Active Directory** (Targets tab) is one source with two parts, both on by default: **Computer accounts** and
  **SQL Server SPNs**. The domain and OU apply to both; the name filter, logon age and workstations apply to computer
  accounts only.
- **SQL connection** is on by default, with Windows authentication unless a SQL login is set on the Credentials tab.
- **Review service accounts in Active Directory** (Options tab) is on by default.
- The HTML report opens when the scan finishes only if **Open the HTML report when the scan finishes** is checked
  (off by default).
- Settings are remembered in `%APPDATA%\SQLMap\ui-settings.json`. Credentials never are: only user names.

**While it runs:**
- Results stream into the **Instances** and **Hosts** grids. Double-click a row for details: probes, services,
  notes and the scan log.
- The **Service accounts** grid fills when the scan ends. Account risk is shown there and in the HTML report.
- The progress bar shows the percent done and the estimated time left (e.g. `37% - about 8 min 10 s left`), based on
  the average pace since scanning started.
- The summary line counts hosts, instances, engines out of support, engines behind the latest update, service
  accounts at risk and hosts not verified, including how many were *access denied*.
- After the hosts, the status line shows *Reviewing service accounts in Active Directory...* while the account
  review runs.
- **Cancel** stops the scan and keeps what was already found.

**Afterwards:**
- Each scan is saved to its own output folder. **Load scan (JSON)** reopens an earlier one.
- The bottom bar opens the HTML report or the output folder.

**Build reference:**
- The Options tab shows the date of the build reference used for patch levels, with an **Update build reference**
  button.
- At startup, when the reference is more than 30 days old and Microsoft Learn is reachable, SQLMap offers to update
  it (see [Patch level](#patch-level-latest-update)).

**Theme:** dark by default. **Light theme** / **Dark theme** (bottom right) switches it, and the choice is
remembered.

## Command line

```powershell
# Local computer
.\SQLMap.Cli.ps1 -OpenReport

# All enabled Windows Server accounts in the current domain + every host with a MSSQLSvc SPN
.\SQLMap.Cli.ps1 -ActiveDirectory -SPN -SqlConnect -OpenReport

# Subnets / ranges, extra SQL ports, more threads
.\SQLMap.Cli.ps1 -IpRange 10.0.1.0/24, 10.0.2.10-60 -TcpPort 1433,14330 -Throttle 64

# Server list + SQL connection details, with alternate Windows credentials for registry/WMI
.\SQLMap.Cli.ps1 -InputFile .\servers.txt -SqlConnect -Credential (Get-Credential CONTOSO\dbaadmin)
```

- **SQL connection:** off by default on the command line. Add `-SqlConnect`, plus `-SqlCredential` for a SQL login.
- **Service account review:** on by default; `-SkipAccountReview` turns it off. The summary lists the accounts by
  risk.
- **Output formats:** `-Format Html, Json, Csv` (all by default). `-OutputPath` defaults to `.\Output`.
- **Progress:** the progress bar shows the percent done and the time left.
- **Summary:** printed at the end:
  - host counts, and instance counts by type
  - engines out of support, behind the latest update and missing security updates
  - service accounts found, checked in AD and at risk, then a table of the accounts sorted by risk
  - an access-denied hint, when there are such hosts
  - a warning when the build reference is old

Each run creates `Output\SQLMap_yyyyMMdd_HHmmss\` containing:

| File | Content |
|---|---|
| `SQLMap.html` | Interactive report (single file, works offline) |
| `SQLMap.json` | Full scan, re-loadable in the UI or with `Import-SQLMapScan` |
| `SQLMap_Instances.csv` | One row per instance: patch level, version source, accounts and their type, engine and SQL Agent state and start mode, logins and risk, SPN accounts, authentication mode, `sa`, sysadmin members, linked servers, availability groups and notes |
| `SQLMap_Hosts.csv` | One row per host: probe results, OS and hardware, instance count and types (`Engine 1, SSRS 1`), local Administrators, real computer name, aliases and MachineGuid |
| `SQLMap_Accounts.csv` | One row per service account: risk, findings, groups, delegation, password, encryption, local admin, instances using it |
| `SQLMap.log` | Scan log |

## HTML report

A single file that works offline in Edge, Chrome or Firefox, with an Auto / Light / Dark theme.

- **Header:** who ran the scan, from where, when, the discovery sources and probes used, and the build reference
  date.
- **Summary tiles:**
  - hosts scanned
  - hosts with SQL Server
  - instances, with a count per type
  - engines out of support
  - engines behind the latest update, with the number missing a security update
  - service accounts at risk (critical or high)
  - hosts not verified, with the number that were access denied
- **Charts:**
  - instances by service type
  - engine components
  - engines by version
  - engines by edition
  - support status
  - patch level, with the build reference date and an age warning
  - host scan results
- **Instances tab:**
  - Sortable, with search and filters for service type, support status, patch level and state.
  - Click a row for full details: build source, servicing branch, latest build and KB, accounts, SPN accounts,
    databases and notes.
  - The details also have a **Security** section: service account type and logins, account risk, authentication
    mode, `sa`, sysadmin members, linked servers and availability groups.
  - The table shows the service account and the SQL Agent account; `(SQL)` or `(AD)` marks where the service
    account came from when it was not the Windows services.
- **Hosts tab:** probe results per host, including the TDS handshake, plus instance count and types. Host details list
  the local Administrators, the real computer name, the other names that reached the same machine, and its MachineGuid.
- **Service accounts tab:** one row per account, sorted by risk, with a filter for critical or high. Click a row for
  every finding and the instances that use the account.
- **Issues tab:** every host that could not be fully checked, and why.
- **Export CSV:** each tab exports its own table.
- **Layout:** tables use the full window width, and long values wrap, so all columns fit on a wide screen. Narrow
  windows get a horizontal scrollbar.
- **Re-rendering:** an older scan can be re-rendered with the current template:
  `Import-SQLMapScan .\SQLMap.json | Export-SQLMapReport -Path .\out -Format Html`.

## Discovery sources (combinable)

| Parameter | Source |
|---|---|
| `-ComputerName` | Explicit names. `srv`, `srv\inst` and `srv,1433` are accepted |
| `-InputFile` | `.txt` (one per line, `#` comments) or `.csv` with a `ComputerName`/`Name`/`Server`/`Host`/`SqlInstance` column |
| `-ActiveDirectory` | Enabled computer accounts: servers only unless `-IncludeWorkstations`. Accounts with no logon in `-ActiveWithinDays` (90) are skipped. Failover-cluster virtual names are skipped (their nodes report them). Narrow with `-NameFilter 'SQL*'` or `-SearchBase 'OU=...'` |
| `-SPN` | Every `MSSQLSvc/*` SPN in the domain (computer and service accounts), with the AD account holding each one |
| `-IpRange` | `10.0.0.0/24`, `10.0.0.1-10.0.0.50`, `10.0.0.1-50` or single IPs (max 65,536 addresses) |
| `-Broadcast` | SQL Browser UDP broadcast on the local subnet (what SSMS "Browse for servers" uses) |

- **AD queries:** `-Domain` and `-Credential` also apply to AD/SPN queries, e.g. when scanning another domain.
- **Duplicates:** a host found by several sources is scanned once. After the scan, the same machine reached through
  several names is merged into one host:
  - **Same IP address:** DNS aliases, `127.0.0.1`, an AD name plus an IP range.
  - **Different IP addresses** (a DNS alias with its own IP, a second NIC): merged when the **real computer name**
    (registry, WMI or SQL Server) matches **and** the **MachineGuid** or the **machine SID** (from the local accounts
    in the Administrators group) matches. Requiring the name keeps VM clones made without sysprep apart, since they
    share the GUID and SID but have different names.
  - The kept entry is the one named after the machine. The other names are listed as aliases, with a log line saying
    why they were merged.
- **Log:** the scan log shows how many targets each source found.
- **Tip:** use `-SPN` together with `-ActiveDirectory`. SPNs can be read by any domain user. They reveal named instances
  and their ports on hosts the scan account cannot read, provide service accounts, and expose Kerberos problems.

## Probes

| Probe | What it does | Needs |
|---|---|---|
| `Ping` | ICMP echo. A failure does not stop the scan | - |
| `Tcp` | TCP connect to `-TcpPort` (default 1433) plus the ports in the host's `MSSQLSvc` SPNs | - |
| TDS handshake | Part of `Tcp`. Sends the SQL Server pre-login packet to each engine port whose build is not known from the registry. The server answers with its exact build before any login, so it works when the login fails or encryption is forced. It also proves the port is a SQL Server; open ports that do not answer are ignored | TCP access to the instance port |
| `Browser` | SQL Server Browser query (UDP 1434): instance names and ports | SQL Browser running |
| `Registry` | Installed instances (incl. SSIS), edition, build, cluster, TCP port, Full-Text/PolyBase, last-running heartbeat, real computer name and MachineGuid | Remote Registry (current user) or WMI (`-Credential`) |
| `Service` | Windows services (state, start mode, account) + OS, cores, memory, virtualization, real computer name + members of the local Administrators group | WMI/CIM over WinRM or DCOM, usually local admin. Local Administrators are read with the Net API (what `net localgroup` uses), fast on domain-joined servers; WMI is the fallback |
| `SqlConnect` | Read-only queries: exact build/CU, databases, sizes, collation, HADR, SSISDB catalog, service accounts, plus security (logins of the service accounts, sysadmin members, authentication mode, `sa`, linked servers, availability groups) | SQL login (Windows auth or `-SqlCredential`). `VIEW SERVER STATE` for CPU count, start time, service accounts and AG roles. A sysadmin login sees all logins and linked servers; others see only part |

- **Skipped probes:** management ports 135, 445 and 5985 are always checked, so probes that cannot work are skipped
  instead of waiting for timeouts.
- **SSIS:** detected from `<version>\DTS\Setup` only when `FeatureList` contains `SQL_DTS_Full`, because SSMS and SSDT
  create `DTS` keys too. It appears as one row per version, e.g. `SRV01 (SSIS130)`.

## How results are interpreted

**Build and version:**
- The build comes from the best source available: SQL connection, registry, TDS handshake, then SQL Browser.
  `VersionSource` records which.
- SQL Server Browser reports the base release (e.g. `15.0.2000.5` on a CU32 server). A Browser version names the
  product but is never used for the patch level.

**Service account:** read from the first source that works. The report marks the column `(SQL)` or `(AD)` when it
came from one of the last two.
1. Windows services (needs local admin).
2. The SQL connection, using `sys.dm_server_services` (needs `VIEW SERVER STATE`, SQL Server 2008 R2 SP1+). This
   also gives the SQL Agent account.

The same two sources give the state and start mode (Auto / Manual / Disabled) of the engine and SQL Agent services,
so they are known even without admin rights on the host. The Windows services win when both are available.
3. The AD account holding the instance's `MSSQLSvc` SPN, with `-SPN` (any domain user can read it). An SPN on the
   computer account means a built-in account (NT Service, LocalSystem or Network Service).

**Kerberos:**
- With `-SPN`, an instance note flags an SPN registered on two accounts (duplicate) or on a different account than
  the one the service runs as. Both break Kerberos.
- When a SQL connection fails with "Cannot generate SSPI context", the problem is noted on the instance and the
  connection is retried by IP address (NTLM).
- A pre-login handshake timeout is reported as a likely TLS version mismatch.

**Confidence:**
- *High:* registry, services, SQL connection or TDS handshake.
- *Medium:* SQL Browser, or SPN + open port.
- *Low:* only an SPN or an open port.

**Host statuses:**
- `SQLFound`, `NoSQLFound`, `Unreachable`, `Unresolved`, `Timeout`, `Error`, `Cancelled`.
- `Inconclusive`: reachable, but neither the registry nor the services could be read, so SQL Server may still be
  there.
- When the reason is *Access denied*, the scan account must be local administrator on the targets (Credentials tab or
  `-Credential`). The end of the scan says how many hosts were affected.
- *Remote Registry service is probably stopped* is shown when port 445 answers but the registry cannot be opened.

## Service account review

After the scan, SQLMap reviews each account that runs a SQL Server service (engine or Agent) in Active Directory. It
is a read-only LDAP pass, and any domain user can read these attributes. It uses the scan's domain (`-Domain` and
`-Credential` apply), and accounts of other domains are marked *Not checked*.

**Which account is reviewed:**

| Service account | Reviewed in AD |
|---|---|
| User account, gMSA, managed service account (`CONTOSO\svc-sql`, `CONTOSO\gmsa-sql$`) | That account |
| Virtual account (`NT Service\MSSQL$X`) or built-in (LocalSystem, Network Service) | The host's computer account, which they use on the network |
| Local account (`.\user`) or Local Service | Not reviewed (not in AD) |

**What is checked, and the risk it adds:**

| Check | Finding | Risk |
|---|---|---|
| Nested membership in Domain Admins, Enterprise Admins, Schema Admins, Administrators, Account / Server / Backup / Print Operators, Group Policy Creator Owners, Key Admins, DnsAdmins (matched by well-known SID, so localized names work) | Privileged group | Critical |
| `TRUSTED_FOR_DELEGATION` (not on a domain controller) | Unconstrained delegation | Critical |
| SQL Server running on a domain controller | Domain controller | Critical |
| `msDS-AllowedToDelegateTo` with `TRUSTED_TO_AUTH_FOR_DELEGATION` / without it | Protocol transition / Constrained delegation | High / Medium |
| Pre-authentication disabled | AS-REP roastable | High |
| User account with SPNs (not a gMSA) | Kerberoastable. High when the password is over a year old or RC4 is allowed (`msDS-SupportedEncryptionTypes` not set or including RC4) | Medium / High |
| Member of the local Administrators group on other scanned hosts (directly or through a group) | Local admin | High |
| Local admin on its own SQL host | Local admin on SQL host | Medium |
| `adminCount = 1` without a privileged group now | adminCount | Medium |
| `PASSWD_NOTREQD` | Password not required | Medium |
| Password never expires / account disabled | | Low |

**Also reported per account:**
- type (user account, gMSA, managed service account, computer account)
- `pwdLastSet` and the password age
- `lastLogonTimestamp`, which AD replicates only every 9-14 days
- encryption types
- SPNs, and all groups (nested)
- the instances using it
- good practice found, e.g. gMSA, AES only, or marked sensitive

**Per instance, with a SQL connection:**
- **Service and Agent account logins:** whether each account has a login and is sysadmin. That can be directly,
  through a Windows group login (matched with the account's AD groups), or through `BUILTIN\Administrators` while
  being local admin on the host. Virtual accounts map to their service SID login (`NT SERVICE\MSSQL$X`, sysadmin by
  default); LocalSystem maps to `NT AUTHORITY\SYSTEM`.
- **Linked servers,** with each login mapping. "(all logins) as remote login 'sa'" means every login reaches the
  remote server as that login.
- **Authentication mode,** and whether `sa` is enabled and renamed.
- **Availability groups:** replicas (with role, commit mode and failover) and listeners. This also shows which hosts
  are replicas of the same data.

**Limits:**
- **Local admin** is known only for hosts whose local Administrators group could be read. That needs the `Service`
  probe and admin rights; the account details say on how many hosts it was checked.
- **Login lists and linked servers** are complete only when the scan login is sysadmin, which the instance details
  show.

## Patch level (latest update)

Each Engine, SSAS and SSIS instance (SQL Server 2008 to 2025) is compared with the official build lists on Microsoft
Learn, using the same reference format and logic as SQLSecReview (check SQL0147):

| Versions | Source |
|---|---|
| 2017-2025 | `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-<year>/build-versions` (same pages and parsing as SQLSecReview) |
| 2008-2016 | "SQL Server complete version list tables" on `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates` |

**Servicing branch:** every service pack has a **CU** branch and a **GDR** branch.
- The CU branch holds cumulative updates, `CUnn + GDR`, QFE security updates and the 2016 SP3 Azure Connect Pack.
- The GDR branch holds security-only updates.
- Branches are named `CU` / `RTM-GDR` for 2017+ (which have no service packs) and `SP3-CU`, `SP4-GDR`, ... for
  2008-2016.
- An unlisted build is placed on the CU branch when it is at or above the first CU build of its service pack.

**Patch status**, against the latest release of the same branch on the **newest service pack**:
- *Latest*.
- *Behind*, with the number of service packs plus releases still to install.
- *Security update missing*: below the latest security release of that branch. This includes any instance on an
  older service pack, e.g. SQL Server 2012 SP3, whose target is SP4 plus the latest GDR.
- *Newer than reference*: the build is newer than the file, so refresh it.
- *Not covered*: SQL Server 2005 and older.
- *Unknown*: the build is not known exactly, e.g. only the SQL Browser answered.

**Exception:** on 2008 / 2008 R2 the last QFE (2015) is below the later security GDRs (2018, 2023), so instances on
the QFE side are pointed to the latest GDR.

**SSRS and Power BI Report Server** ship on their own release track and are not compared.

### Keeping the reference current

The reference is stored in `src/SQLMap/Data/sql-update-reference.json`, in the same format as SQLSecReview's
`rules/sql-update-reference.json`.
- **Freshness:** it is considered current for 30 days (`MaxAgeDays`). The report shows the retrieval date, and warns
  when it was older than that at scan time.
- **Scans never go to the internet.** Only the update below does.

**Command line:**

```powershell
Import-Module .\src\SQLMap\SQLMap.psd1
Update-SQLMapBuildReference                      # reads the Microsoft Learn pages (2008-2025)
Update-SQLMapBuildReference -Path ..\SQLSecReview\rules\sql-update-reference.json   # or import an existing file
```

Importing SQLSecReview's file, which covers only 2017-2025, keeps the 2008-2016 rows already in SQLMap's file.

**Windows UI:**
- **Update build reference** on the Options tab runs the update in the background.
- At startup, when the reference is older than 30 days, SQLMap checks in the background whether Microsoft Learn is
  reachable. Only then does it ask whether to update. Nothing is downloaded without a click.
- **Not now** asks again in 7 days. **Don't ask again on this computer**, or the Options checkbox, turns the startup
  check off. Turn it off on client servers that must not reach the internet.

## Using the module directly

```powershell
Import-Module .\src\SQLMap\SQLMap.psd1

$scan = Invoke-SQLMapScan -ActiveDirectory -SPN -SqlConnect -Verbose
$scan.Instances | Where-Object PatchStatus -eq 'Security update missing' | Format-Table SqlInstance, Version, UpdateLevel, LatestUpdate
$scan | Export-SQLMapReport -Path .\Output\Contoso

# Service accounts with critical or high findings, and the instances whose service account is sysadmin
$scan.Accounts | Where-Object Risk -in 'Critical', 'High' | Format-Table Account, Type, Risk, Tags
$scan.Instances | Where-Object ServiceAccountLogin -like 'sysadmin*' | Format-Table SqlInstance, ServiceAccount, ServiceAccountLogin

# Single host
Invoke-SQLMapComputerScan -Target SRV01 -Probe Ping, Tcp, Registry, Service, SqlConnect

# Skip the AD review of service accounts
Invoke-SQLMapScan -ComputerName SRV01, SRV02 -SqlConnect -SkipAccountReview

# Re-render an old scan with the current report template
Import-SQLMapScan .\Output\Contoso\SQLMap.json | Export-SQLMapReport -Path .\Output\Contoso -Format Html
```

Exported functions:
- `Find-SQLMapTarget`
- `Invoke-SQLMapScan`
- `Invoke-SQLMapComputerScan`
- `Export-SQLMapReport`
- `Import-SQLMapScan`
- `Update-SQLMapBuildReference`

The scan object has `Hosts`, `Instances`, `Accounts` (service account review) and `Summary`.

`Invoke-SQLMapScan -State <synchronized hashtable>` exposes progress counters, a log queue, a finished-host queue and
a `CancelRequested` flag. This is how the WinForms UI follows and cancels a scan.

## Project layout

```
SQLMap.cmd                     double-click launcher for the UI (console shows the startup steps)
SQLMap.ps1                     UI entry point (relaunches itself in STA if needed)
SQLMap.Cli.ps1                 command line entry point
src/SQLMapUI/SQLMap.UI.ps1     WinForms UI (scan and updates run in background runspaces; dark/light themes)
assets/SQLMap.ico|.png|.svg    app icon (window, report favicon/logo)
tools/New-SQLMapIcon.ps1       regenerates the icon files
src/SQLMap/
  SQLMap.psd1 / .psm1          module
  Public/                      exported functions
  Private/
    Discovery.ps1              AD, SPN (with account owners), IP range, broadcast, file
    Probe.Network.ps1          DNS, ping, TCP, TDS pre-login handshake, SQL Browser
    Probe.Registry.ps1         Remote Registry / WMI StdRegProv readers
    Probe.Cim.ps1              services, OS/hardware, local Administrators (Net API, WMI fallback)
    Probe.SqlConnect.ps1       SQL queries (inventory, service account logins, linked servers, AGs, sa)
    Merge.ps1                  evidence merge, confidence, service account, SPN findings, lifecycle
    AccountRisk.ps1            service account review in AD (groups, delegation, Kerberoasting, local admin)
    BuildReference.ps1         patch level against the Microsoft Learn build lists
    Common.ps1                 helpers
  Data/SqlProducts.json        versions + Microsoft lifecycle dates (review periodically)
  Data/sql-update-reference.json   build reference (refresh with Update-SQLMapBuildReference)
  Templates/report.html        report template (data is embedded at export time)
```

## Notes

- **Version format:** versions are shown as SQL Server reports them (`SERVERPROPERTY('ProductVersion')`). The registry
  `PatchLevel` stores the service pack in the minor number (`13.3.7095.1`, `10.53.6000.34`), which SQLMap normalizes
  to `13.0.7095.1` / `10.50.6000.34`.
- **Lifecycle dates** live in `src/SQLMap/Data/SqlProducts.json`. SQL Server 2025 dates are not filled in yet, so
  2025 instances show *Supported (dates not set)*.
- **Failover cluster instances** appear once per node in the tables and are counted once (by `SqlInstance`) in the
  summary.
- **Instance counts:** a host's count includes every service type (Engine, SSAS, SSRS, PBIRS, SSIS). The `Types`
  column and `EngineCount` give the breakdown.
- **Older browsers:** the HTML report needs a modern browser (Edge, Chrome, Firefox). On older servers that only
  have IE11, copy the file to a workstation.
