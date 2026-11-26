function Export-SQLMapReport {
    <#
    .SYNOPSIS
        Writes a scan to HTML (self-contained, works offline), JSON and/or CSV files.
    .DESCRIPTION
        Files written to -Path:
          <BaseName>.html            interactive report
          <BaseName>.json            full scan (re-import with Import-SQLMapScan)
          <BaseName>_Instances.csv   one row per instance
          <BaseName>_Hosts.csv       one row per scanned host
        Returns an object with the full path of each file written.
    .EXAMPLE
        Invoke-SQLMapScan -ActiveDirectory | Export-SQLMapReport -Path .\Output\Contoso
    .EXAMPLE
        Import-SQLMapScan .\Output\Contoso\SQLMap.json | Export-SQLMapReport -Path .\Output\Contoso -Format Html
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Scan,
        [Parameter(Mandatory)]
        [string]$Path,
        [ValidateSet('Html', 'Json', 'Csv')]
        [string[]]$Format = @('Html', 'Json', 'Csv'),
        [string]$BaseName = 'SQLMap'
    )
    process {
        if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -ItemType Directory -Force }
        $folder = (Resolve-Path -LiteralPath $Path).ProviderPath
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $out = [ordered]@{ Html = $null; Json = $null; InstancesCsv = $null; HostsCsv = $null }

        if ($Format -contains 'Json') {
            $file = Join-Path $folder "$BaseName.json"
            [System.IO.File]::WriteAllText($file, ($Scan | ConvertTo-Json -Depth 10), $utf8NoBom)
            $out.Json = $file
        }

        if ($Format -contains 'Html') {
            $templatePath = Join-Path $script:ModuleRoot 'Templates\report.html'
            $template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
            # '<' only appears inside JSON strings; < keeps '</script>' from closing the data block
            $json = ($Scan | ConvertTo-Json -Depth 10 -Compress).Replace('<', '<')
            $html = $template.Replace('/*__SQLMAP_DATA__*/', $json)
            $file = Join-Path $folder "$BaseName.html"
            [System.IO.File]::WriteAllText($file, $html, $utf8NoBom)
            $out.Html = $file
        }

        if ($Format -contains 'Csv') {
            $file = Join-Path $folder "${BaseName}_Instances.csv"
            @($Scan.Instances) | Where-Object { $_ } | ForEach-Object {
                $i = $_
                [pscustomobject][ordered]@{
                    ComputerName      = $i.ComputerName
                    SqlInstance       = $i.SqlInstance
                    InstanceName      = $i.InstanceName
                    ServiceType       = $i.ServiceType
                    ProductName       = $i.ProductName
                    Version           = $i.Version
                    VersionSource     = $(if ($i.PSObject.Properties['VersionSource']) { $i.VersionSource } else { $null })
                    ProductLevel      = $i.ProductLevel
                    UpdateLevel       = $i.UpdateLevel
                    PatchStatus       = $i.PatchStatus
                    LatestUpdate      = $i.LatestUpdate
                    LatestBuild       = $i.LatestBuild
                    LatestKB          = $i.LatestKB
                    ServicingBranch   = $i.ServicingBranch
                    SecurityUpdateBuild = $i.SecurityUpdateBuild
                    UpdatesBehind     = $i.UpdatesBehind
                    Edition           = $i.Edition
                    SupportStatus     = $i.SupportStatus
                    MainstreamEndDate = $i.MainstreamEndDate
                    ExtendedEndDate   = $i.ExtendedEndDate
                    IsRunning         = $i.IsRunning
                    ServiceState      = $i.ServiceState
                    StartMode         = $i.StartMode
                    ServiceAccount    = $i.ServiceAccount
                    AgentState        = $i.AgentState
                    TcpPort           = $i.TcpPort
                    DynamicPort       = $i.DynamicPort
                    Clustered         = $i.Clustered
                    ClusterName       = $i.ClusterName
                    ClusterNodes      = Join-SQLMapList $i.ClusterNodes
                    Components        = Join-SQLMapList $i.Components
                    SsisCatalog       = $i.SsisCatalog
                    LastHeartbeatUtc  = $i.LastHeartbeatUtc
                    DatabaseCount     = $i.DatabaseCount
                    DataSizeGB        = $i.DataSizeGB
                    LogSizeGB         = $i.LogSizeGB
                    MaxServerMemoryMB = $i.MaxServerMemoryMB
                    CpuCount          = $i.CpuCount
                    Collation         = $i.Collation
                    IsHadrEnabled     = $i.IsHadrEnabled
                    SqlStartTime      = $i.SqlStartTime
                    SqlConnectStatus  = $i.SqlConnectStatus
                    Confidence        = $i.Confidence
                    DetectedBy        = Join-SQLMapList $i.DetectedBy
                    Notes             = Join-SQLMapList $i.Notes ' | '
                }
            } | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
            $out.InstancesCsv = $file

            $file = Join-Path $folder "${BaseName}_Hosts.csv"
            @($Scan.Hosts) | Where-Object { $_ } | ForEach-Object {
                $h = $_
                $hi = $h.HostInfo
                $pr = $h.Probes
                $pm = $h.ProbeMessages
                $getProp = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.$n } elseif ($o -is [System.Collections.IDictionary]) { $o[$n] } else { $null } }
                [pscustomobject][ordered]@{
                    ComputerName      = $h.ComputerName
                    DnsName           = $h.DnsName
                    IPAddress         = $h.IPAddress
                    Status            = $h.Status
                    StatusDetail      = $h.StatusDetail
                    InstanceCount     = $h.InstanceCount
                    EngineCount       = & $getProp $h 'EngineCount'
                    InstanceTypes     = & $getProp $h 'InstanceTypes'
                    Sources           = Join-SQLMapList $h.Sources
                    OpenPorts         = Join-SQLMapList $h.OpenPorts
                    OSCaption         = $(if ($hi) { $hi.OSCaption } else { $h.AdOperatingSystem })
                    OSVersion         = & $getProp $hi 'OSVersion'
                    Domain            = & $getProp $hi 'Domain'
                    Manufacturer      = & $getProp $hi 'Manufacturer'
                    Model             = & $getProp $hi 'Model'
                    IsVirtual         = & $getProp $hi 'IsVirtual'
                    Sockets           = & $getProp $hi 'Sockets'
                    Cores             = & $getProp $hi 'Cores'
                    LogicalProcessors = & $getProp $hi 'LogicalProcessors'
                    MemoryGB          = & $getProp $hi 'MemoryGB'
                    LastBootTime      = & $getProp $hi 'LastBootTime'
                    ProbeDns          = & $getProp $pr 'Dns'
                    ProbePing         = & $getProp $pr 'Ping'
                    ProbeTcp          = & $getProp $pr 'Tcp'
                    ProbeBrowser      = & $getProp $pr 'Browser'
                    ProbeRegistry     = & $getProp $pr 'Registry'
                    ProbeService      = & $getProp $pr 'Service'
                    ProbePrelogin     = & $getProp $pr 'Prelogin'
                    ProbeSqlConnect   = & $getProp $pr 'SqlConnect'
                    RegistryMessage   = & $getProp $pm 'Registry'
                    ServiceMessage    = & $getProp $pm 'Service'
                    SPNs              = Join-SQLMapList $h.SPNs
                    DurationMs        = $h.DurationMs
                }
            } | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
            $out.HostsCsv = $file
        }
        [pscustomobject]$out
    }
}
