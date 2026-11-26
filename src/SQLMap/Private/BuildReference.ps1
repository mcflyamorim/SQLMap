# Build reference: official SQL Server build lists from Microsoft Learn, saved offline as
# Data/sql-update-reference.json by Update-SQLMapBuildReference. Same file format as SQLSecReview's
# rules/sql-update-reference.json (SchemaVersion 1), so either project's file can be copied to the other.
#
# Servicing branches ('Branch' in the file):
#   2017-2025  'CU' (cumulative updates, incl. 'CUnn + GDR') and 'RTM-GDR' (RTM + security-only GDRs)
#   2008-2016  the same two kinds per service pack: 'SP3-CU', 'SP3-GDR', 'RTM-CU', ...
#              (the CU kind also holds QFE security updates and the 2016 SP3 Azure Connect Pack;
#               RTM / service pack baselines are the root of the GDR kind)
# An instance is compared with the latest release of its branch on the NEWEST service pack (currency) and with
# the latest security release there (security floor), as SQLSecReview check SQL0147 does for 2017+.
# An instance on an older service pack is therefore behind and missing security updates.

$script:BuildRefPath = Join-Path $PSScriptRoot '..\Data\sql-update-reference.json'
$script:BuildRef = $null

function ConvertTo-SQLMapNormalizedVersion {
    # Registry PatchLevel stores the service pack in the minor number (13.3.7095.1 = 13.0.7095.1 SP3,
    # 10.53.6000.34 = 10.50.6000.34). Returns the version as SERVERPROPERTY('ProductVersion') reports it.
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $parts = $Version.Trim() -split '\.'
    $nums = @()
    foreach ($p in $parts) { $n = 0; if (-not [int]::TryParse($p, [ref]$n)) { return $Version }; $nums += $n }
    if ($nums.Count -lt 3) { return $Version }
    $major = $nums[0]; $minor = $nums[1]
    if ($major -eq 10) { $minor = if ($minor -ge 50) { 50 } else { 0 } }
    elseif ($major -ge 9) { $minor = 0 }
    $nums[1] = $minor
    ($nums -join '.')
}

function ConvertTo-SQLMapSpOrder {
    # 'RTM' -> 0, 'SP1' -> 1, ...
    param([string]$ServicePack)
    if ($ServicePack -match '^SP(\d+)$') { return [int]$Matches[1] }
    0
}

function Get-SQLMapBuildReference {
    # Returns @{ Available; LastUpdated (yyyy-MM-dd); RetrievedUtc; MaxAgeDays; Scope; Products = @{ '16.0' = [builds sorted] } }
    param([switch]$Reload)
    if ($script:BuildRef -and -not $Reload) { return $script:BuildRef }
    $path = [System.IO.Path]::GetFullPath($script:BuildRefPath)
    $empty = @{ Available = $false; LastUpdated = $null; RetrievedUtc = $null; MaxAgeDays = 30; Scope = $null; Products = @{}; Path = $path }
    if (-not (Test-Path -LiteralPath $path)) { $script:BuildRef = $empty; return $script:BuildRef }

    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($raw.SchemaVersion -ne 1 -or -not $raw.PSObject.Properties['Builds']) {
        Write-Warning "Unsupported build reference format: $path"
        $script:BuildRef = $empty; return $script:BuildRef
    }
    $products = @{}
    foreach ($b in @($raw.Builds)) {
        $v = $null
        if (-not $b -or -not [version]::TryParse([string]$b.Version, [ref]$v)) { continue }
        $bm = [regex]::Match([string]$b.Branch, '^(?:(RTM|SP\d+)-)?(CU|GDR)$')
        if (-not $bm.Success) { continue }
        $sp = if ($bm.Groups[1].Success) { $bm.Groups[1].Value } else { 'RTM' }
        $label = ([string]$b.Label -replace '\s*\(Latest\)\s*$', '').Trim()
        $released = [string]$b.ReleasedOn
        # Several 'GDR' / 'CU27 + GDR' rows share a label: the release date tells them apart
        $display = if ($label -match 'GDR|QFE' -and $released) { "$label ($released)" } else { $label }
        $entry = [pscustomobject]@{
            Version         = $v
            Branch          = [string]$b.Branch
            ServicePack     = $sp
            SpOrder         = (ConvertTo-SQLMapSpOrder $sp)
            Kind            = $bm.Groups[2].Value
            Label           = $display
            SecurityRelease = [bool]$b.SecurityRelease
            Removed         = ($label -match '\(Removed\)')
            ReleasedOn      = $released
            KB              = $(if ($b.PSObject.Properties['KB'] -and $b.KB) { [string]$b.KB } else { $null })
        }
        $key = "$($v.Major).$($v.Minor)"   # 10.0 (2008) and 10.50 (2008 R2) share major 10
        if (-not $products.ContainsKey($key)) { $products[$key] = New-Object System.Collections.Generic.List[object] }
        $products[$key].Add($entry)
    }
    $sorted = @{}
    foreach ($k in @($products.Keys)) { $sorted[$k] = @($products[$k] | Sort-Object Version) }

    $retrieved = $null
    try { $retrieved = [datetime]::Parse([string]$raw.RetrievedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    $maxAge = 30
    if ($raw.PSObject.Properties['MaxAgeDays'] -and [double]$raw.MaxAgeDays -gt 0) { $maxAge = [int]$raw.MaxAgeDays }
    $script:BuildRef = @{
        Available    = ($sorted.Count -gt 0)
        LastUpdated  = $(if ($retrieved) { $retrieved.ToUniversalTime().ToString('yyyy-MM-dd') } else { $null })
        RetrievedUtc = $retrieved
        MaxAgeDays   = $maxAge
        Scope        = [string]$raw.Scope
        Products     = $sorted
        Path         = $path
    }
    $script:BuildRef
}

function Get-SQLMapBuildInfo {
    # Servicing branch, current level, latest release, security floor and how many updates behind, for one build.
    param([string]$Version)
    $info = [ordered]@{
        UpdateLevel         = $null      # e.g. 'CU27', 'CU27 + GDR (2026-10-13)', 'SP3 CU4 + GDR (2023-10-10)', 'SP4'
        ServicingBranch     = $null      # 'CU', 'RTM-GDR', 'SP3-CU', 'SP4-GDR', ...
        LatestUpdate        = $null      # latest release of the matching branch on the newest service pack
        LatestBuild         = $null
        LatestKB            = $null
        SecurityUpdateBuild = $null      # latest security release of that branch
        UpdatesBehind       = $null      # newer service packs + newer releases of the target branch
        PatchStatus         = 'Unknown'  # Latest | Behind | Security update missing | Newer than reference | Not covered | Unknown
    }
    $norm = ConvertTo-SQLMapNormalizedVersion $Version
    $v = $null
    if (-not $norm -or -not [version]::TryParse($norm, [ref]$v)) { return $info }
    $ref = Get-SQLMapBuildReference
    if (-not $ref.Available) { return $info }
    $builds = $ref.Products["$($v.Major).$($v.Minor)"]
    if (-not $builds) { $info.PatchStatus = 'Not covered'; return $info }   # e.g. SQL 2005, or newer than the file
    $installed = New-Object System.Version($v.Major, $v.Minor, $v.Build, [Math]::Max(0, $v.Revision))

    # 1. Service pack: exact match, else the newest service pack whose first build is at or below the installed one
    #    (build numbers grow with each service pack)
    if ($v.Revision -lt 0) {
        # major.minor.build only (TDS pre-login handshake): match on the build number
        $exact = @($builds | Where-Object { $_.Version.Build -eq $v.Build })
        if ($exact.Count) { $installed = ($exact | Select-Object -Last 1).Version }
    }
    else { $exact = @($builds | Where-Object { $_.Version -eq $installed }) }
    if ($exact.Count) { $spOrder = $exact[0].SpOrder }
    else {
        $spOrder = 0
        foreach ($g in ($builds | Group-Object SpOrder)) {
            $first = ($g.Group | Sort-Object Version | Select-Object -First 1).Version
            if ($installed -ge $first -and [int]$g.Name -gt $spOrder) { $spOrder = [int]$g.Name }
        }
    }
    $mySp = @($builds | Where-Object { $_.SpOrder -eq $spOrder })

    # 2. Kind (CU or GDR): exact match, else CU when at or above the first CU build of that service pack
    #    (GDR builds are numbered below CU builds of the same service pack)
    $exactKinds = @($exact | ForEach-Object { $_.Kind } | Sort-Object -Unique)
    if ($exactKinds.Count -eq 1) { $kind = $exactKinds[0] }
    elseif ($exact.Count) { return $info }   # same build listed in both kinds: cannot tell
    else {
        $cuMin = $mySp | Where-Object { $_.Kind -eq 'CU' } | Select-Object -First 1
        $kind = if ($cuMin -and $installed -ge $cuMin.Version) { 'CU' } else { 'GDR' }
    }
    $sp = if ($mySp.Count) { $mySp[0].ServicePack } else { 'RTM' }
    $info.ServicingBranch = if ($sp -eq 'RTM' -and $kind -eq 'CU' -and $v.Major -ge 14) { 'CU' } else { "$sp-$kind" }

    $myBranch = @($mySp | Where-Object { $_.Kind -eq $kind })
    $current = @($myBranch | Where-Object { $_.Version -le $installed }) | Select-Object -Last 1
    $info.UpdateLevel = if ($exact.Count) { $exact[0].Label }
                        elseif ($current) { "$($current.Label) (build $($v.Build) not in reference)" }
                        else { "$($info.ServicingBranch) branch (build $($v.Build) not in reference)" }

    # 3. Target: same kind on the newest service pack (the other kind when that service pack has none of it,
    #    e.g. SQL 2012 SP4 only has GDRs). Pulled updates are never 'the latest'.
    $newestSp = ($builds | Measure-Object -Property SpOrder -Maximum).Maximum
    $released = @($builds | Where-Object { -not $_.Removed -and $_.SpOrder -eq $newestSp })
    $target = @($released | Where-Object { $_.Kind -eq $kind -and $_.Label -notmatch '^(RTM|SP\d+)$' })
    if (-not $target.Count) { $target = @($released | Where-Object { $_.Kind -ne $kind -and $_.Label -notmatch '^(RTM|SP\d+)$' }) }
    elseif ($kind -eq 'CU') {
        # SQL 2008 / 2008 R2: the last QFE (2015) is below the later security GDRs (2018, 2023), which install on
        # top of it. A GDR build above every CU build is the way forward (never the case for 2012+, where GDR
        # builds stay below the CU builds).
        $maxCu = ($target | Select-Object -Last 1).Version
        $above = @($released | Where-Object { $_.Kind -eq 'GDR' -and $_.Version -gt $maxCu -and $_.Label -notmatch '^(RTM|SP\d+)$' })
        if ($above.Count) { $target = @(@($target) + $above | Sort-Object Version) }
    }
    if (-not $target.Count) { $target = $released }   # service pack baseline only
    $latest = $target | Select-Object -Last 1
    $floor = @($target | Where-Object { $_.SecurityRelease }) | Select-Object -Last 1
    if (-not $latest) { return $info }
    $info.LatestUpdate = $latest.Label
    $info.LatestBuild  = $latest.Version.ToString()
    $info.LatestKB     = $latest.KB
    if ($floor) { $info.SecurityUpdateBuild = $floor.Version.ToString() }

    # Updates behind: service packs still to install + releases of the target branch after the installed build
    $newerSps = @($builds | Where-Object { $_.SpOrder -gt $spOrder -and $_.Label -match '^SP\d+$' }).Count
    $info.UpdatesBehind = $newerSps + @($target | Where-Object { $_.Version -gt $installed -and $_.Label -notmatch '^(RTM|SP\d+)$' }).Count

    if ($spOrder -eq $newestSp -and $installed -gt $latest.Version) { $info.PatchStatus = 'Newer than reference'; $info.UpdatesBehind = $null }
    elseif ($floor -and $installed -lt $floor.Version) { $info.PatchStatus = 'Security update missing' }
    elseif ($info.UpdatesBehind -eq 0) { $info.PatchStatus = 'Latest' }
    else { $info.PatchStatus = 'Behind' }
    $info
}
