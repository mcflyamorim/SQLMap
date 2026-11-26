function Update-SQLMapBuildReference {
    <#
    .SYNOPSIS
        Refreshes the SQL Server build reference used to report each instance's update level and the latest update.
    .DESCRIPTION
        Reads the official build lists on Microsoft Learn and saves them to the module's Data\sql-update-reference.json:

          SQL Server 2017-2025  https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-<year>/build-versions
                                (same pages and parsing as SQLSecReview's tools/Update-SqlSecurityReference.ps1)
          SQL Server 2008-2016  "SQL Server complete version list tables" on
                                https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates

        Same file format as SQLSecReview's rules\sql-update-reference.json (SchemaVersion 1), so -Path can import that
        file. Branch is 'CU' / 'RTM-GDR' for 2017+ and '<SP>-CU' / '<SP>-GDR' (e.g. 'SP3-CU', 'SP4-GDR') for 2008-2016.

        Scans never go to the internet: refresh before visiting a client. The reference is considered current for
        MaxAgeDays (30); older references are flagged in the report.

        With -Path, the file only replaces the current one when it is newer (-Force replaces it anyway). Versions
        missing from the new file (e.g. 2008-2016 when importing SQLSecReview's file) and the hand-maintained
        Lifecycle list are carried over from the current file.
    .EXAMPLE
        Update-SQLMapBuildReference
    .EXAMPLE
        Update-SQLMapBuildReference -Path '..\SQLSecReview\rules\sql-update-reference.json'
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int[]]$Year = @(2017, 2019, 2022, 2025),
        [switch]$Force
    )
    $target = [System.IO.Path]::GetFullPath($script:BuildRefPath)
    $before = Get-SQLMapBuildReference
    $previous = $null
    if (Test-Path -LiteralPath $target) {
        try { $previous = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
    }

    if ($Path) {
        $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [System.Text.Encoding]::UTF8)
        try { $data = $text | ConvertFrom-Json } catch { throw "'$Path' is not valid JSON: $($_.Exception.Message)" }
    }
    else {
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($e in (Get-SQLMapLearnBuildList -Year $Year)) { $entries.Add($e) }
        $data = [pscustomobject][ordered]@{
            SchemaVersion = 1
            RetrievedUtc  = [datetime]::UtcNow.ToString('o')
            MaxAgeDays    = 30
            Scope         = 'SQL Server 2008-2025 Windows Database Engine (Microsoft Learn build lists). GDR rows identify the servicing security floor; CU currency is reported separately. 2008-2016 branches are per service pack (e.g. SP3-CU, SP4-GDR). Other releases and unlisted builds require review.'
            Builds        = $entries.ToArray()
        }
        $text = $null
    }

    # Validate (also covers files imported with -Path)
    if ($data.SchemaVersion -ne 1 -or -not $data.PSObject.Properties['RetrievedUtc'] -or -not $data.PSObject.Properties['Builds']) {
        throw 'The build reference does not look like a sql-update-reference.json file (SchemaVersion 1, RetrievedUtc, Builds).'
    }
    $valid = @($data.Builds | Where-Object { $_ -and $_.Version -and $_.Branch -match '^((RTM|SP\d)-)?(CU|GDR)$' })
    if ($valid.Count -lt 20) { throw "The build reference has only $($valid.Count) usable build rows." }
    $retrieved = [datetime]::Parse([string]$data.RetrievedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()

    if ($previous) {
        # Versions the new file does not have (SQLSecReview's file covers 2017-2025 only): keep the current rows
        $productKey = { param($b) $v = [version]([string]$b.Version); "$($v.Major).$($v.Minor)" }
        $newKeys = @($data.Builds | Where-Object { $_ } | ForEach-Object { & $productKey $_ } | Sort-Object -Unique)
        $carried = @($previous.Builds | Where-Object { $_ -and $_.Version -and ((& $productKey $_) -notin $newKeys) })
        if ($carried.Count) {
            $data.Builds = @($data.Builds) + $carried
            $valid = @($valid) + $carried
            $text = $null
            Write-Verbose "Kept $($carried.Count) build rows of versions not in the new file"
        }
        # Hand-maintained end-of-support list (SQLSecReview)
        foreach ($name in 'LifecycleSource', 'LifecycleReviewedOn', 'LifecycleNote', 'Lifecycle') {
            if ($previous.PSObject.Properties[$name] -and -not $data.PSObject.Properties[$name]) {
                $data | Add-Member -NotePropertyName $name -NotePropertyValue $previous.$name
                $text = $null
            }
        }
    }

    $replace = $Force -or -not $Path -or -not $before.RetrievedUtc -or ($retrieved -gt $before.RetrievedUtc.ToUniversalTime())
    if ($replace) {
        if (-not $text) { $text = ConvertTo-Json $data -Depth 10 }
        $dir = Split-Path $target
        if (-not (Test-Path $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
        $temp = "$target.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllText($temp, $text, (New-Object System.Text.UTF8Encoding($false)))
            if ([System.IO.File]::Exists($target)) { [System.IO.File]::Replace($temp, $target, [System.Management.Automation.Language.NullString]::Value) }
            else { [System.IO.File]::Move($temp, $target) }
        }
        finally { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } }
        $null = Get-SQLMapBuildReference -Reload
    }
    $ref = Get-SQLMapBuildReference
    [pscustomobject][ordered]@{
        PreviousDate = $before.LastUpdated
        NewDate      = $retrieved.ToString('yyyy-MM-dd')
        Updated      = [bool]$replace
        Builds       = $valid.Count
        Versions     = (@($ref.Products.Keys | Sort-Object { [version]$_ }) -join ', ')
        Path         = $target
    }
}

function Get-SQLMapLearnBuildList {
    # Parses the Microsoft Learn build lists. Throws when a page cannot be read or parsed (the current file is kept).
    param([int[]]$Year)
    # Windows PowerShell 5.1 does not offer TLS 1.2 by default
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    # learn.microsoft.com answers 403 to the default Windows PowerShell user agent (same as SQLSecReview)
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0'
    $enUS = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    $getPage = { param($url) Write-Verbose "Reading $url"; (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $userAgent -ErrorAction Stop).Content }
    $getCells = {
        param($rowHtml)
        , @([regex]::Matches($rowHtml, '(?is)<td\b[^>]*>(.*?)</td>') | ForEach-Object {
            ([System.Net.WebUtility]::HtmlDecode([regex]::Replace($_.Groups[1].Value, '<[^>]+>', '')).Trim() -replace '\s+', ' ')
        })
    }
    $getDate = {
        param($text, $version)
        $d = [datetime]::Parse($text, $enUS)
        if ($d.Date -gt [datetime]::UtcNow.Date) { throw "Future-dated reference entry: $version" }
        $d.ToString('yyyy-MM-dd')
    }

    # --- SQL Server 2017-2025: one page per version (SQLSecReview parsing) -----------------------------
    foreach ($y in $Year) {
        $url = "https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-$y/build-versions"
        $html = & $getPage $url
        $count = 0
        foreach ($tr in [regex]::Matches($html, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
            $cells = & $getCells $tr.Groups[1].Value
            if ($cells.Count -lt 3 -or $cells[1] -notmatch '^1[4-7]\.0\.\d+\.\d+$') { continue }
            $label = $cells[0]; $version = $cells[1]
            if ($label -notmatch 'CU|GDR|RTM') { continue }
            $kb = @($cells | Where-Object { $_ -match '^KB\d{6,8}$' }) | Select-Object -First 1
            [pscustomobject][ordered]@{
                Version = $version; Major = ([version]$version).Major
                Branch = $(if ($label -match 'CU') { 'CU' } else { 'RTM-GDR' })
                Label = $label; SecurityRelease = ($label -match 'GDR')
                ReleasedOn = (& $getDate $cells[-1] $version); KB = $kb; Source = $url
            }
            $count++
        }
        if ($count -lt 5) { throw "Could not parse enough build rows for SQL Server $y; the current reference was kept." }
    }

    # --- SQL Server 2008-2016: complete version list tables (Build | Service pack | Update | KB | Release date) ---
    $url = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates'
    $html = & $getPage $url
    $wanted = @('SQL Server 2016', 'SQL Server 2014', 'SQL Server 2012', 'SQL Server 2008 R2', 'SQL Server 2008')
    $rows = @{}
    $title = $null
    foreach ($m in [regex]::Matches($html, '(?is)<h[2-4]\b[^>]*>(.*?)</h[2-4]>|<table\b.*?</table>')) {
        if ($m.Value -notlike '<table*') { $title = [regex]::Replace($m.Groups[1].Value, '<[^>]+>', '').Trim(); continue }
        if ($title -notin $wanted -or $rows.ContainsKey($title)) { continue }
        $rows[$title] = @(foreach ($tr in [regex]::Matches($m.Value, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
            $c = & $getCells $tr.Groups[1].Value
            if ($c.Count -ge 5 -and $c[0] -match '^1[0-3]\.\d+\.\d+\.\d+$') {
                [pscustomobject]@{ Version = ([version]$c[0]).ToString(); SP = $c[1]; Update = $c[2]; KB = $c[3]; Date = $c[-1] }
            }
        })
    }
    foreach ($product in $wanted) {
        $list = @($rows[$product] | Sort-Object { [version]$_.Version })
        if ($list.Count -lt 5) { throw "Could not parse enough build rows for $product; the current reference was kept." }
        # Service pack baselines (RTM / 'Service Pack' rows) place rows whose SP column is missing ('None')
        $bases = @($list | Where-Object { $_.Update -in 'RTM', 'Service Pack' })
        foreach ($r in $list) {
            $sp = $r.SP
            if ($sp -notmatch '^(RTM|SP\d)$') {
                $base = @($bases | Where-Object { [version]$_.Version -le [version]$r.Version }) | Select-Object -Last 1
                $sp = if ($base) { $base.SP } else { 'RTM' }
            }
            $u = $r.Update
            # Kind: CU branch (CUs, QFE security updates, 2016 SP3 Azure Connect Pack) or GDR branch (GDRs, SP/RTM baselines)
            $isCu = $u -match '^CU\d|QFE|Azure Connect'
            $security = if ($u -in 'RTM', 'Service Pack') { $false } elseif ($isCu) { $u -match 'GDR|QFE|ADV\d|MS\d\d-' } else { $true }
            $bulletin = [regex]::Match($u, '(ADV\d+|MS\d\d-\d+)').Value
            $label = if ($u -eq 'RTM') { 'RTM' }
                     elseif ($u -eq 'Service Pack') { $sp }
                     elseif ($u -match '^CU(\d+)') { "$sp CU$($Matches[1])" + $(if ($u -match 'GDR') { ' + GDR' } elseif ($bulletin) { " + $bulletin" } else { '' }) }
                     elseif ($u -match 'Azure Connect') { "$sp Azure Connect Pack" + $(if ($u -match 'GDR') { ' + GDR' } else { '' }) }
                     elseif ($u -match 'QFE') { "$sp QFE" + $(if ($bulletin) { " $bulletin" } else { '' }) }
                     else { "$sp GDR" + $(if ($bulletin) { " $bulletin" } else { '' }) }
            [pscustomobject][ordered]@{
                Version = $r.Version; Major = ([version]$r.Version).Major
                Branch = "$sp-$(if ($isCu) { 'CU' } else { 'GDR' })"
                Label = $label; SecurityRelease = [bool]$security
                ReleasedOn = (& $getDate $r.Date $r.Version)
                KB = $(if ($r.KB -match '^KB\d+$') { $r.KB } else { $null })
                Source = $url
            }
        }
    }
}
