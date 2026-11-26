<#
.SYNOPSIS
    SQLMap command line: discover SQL Server services on a network and write HTML/JSON/CSV reports.
.DESCRIPTION
    Wraps Invoke-SQLMapScan + Export-SQLMapReport. Every scan gets its own output folder:
        <OutputPath>\SQLMap_yyyyMMdd_HHmmss\  SQLMap.html, SQLMap.json, SQLMap_Instances.csv, SQLMap_Hosts.csv, SQLMap.log
.EXAMPLE
    .\SQLMap.Cli.ps1
    Scans the local computer.
.EXAMPLE
    .\SQLMap.Cli.ps1 -ActiveDirectory -SPN -OpenReport
    Scans every enabled Windows Server computer account in the current domain plus every host with a MSSQLSvc SPN.
.EXAMPLE
    .\SQLMap.Cli.ps1 -IpRange 10.0.1.0/24 -TcpPort 1433,14330 -Throttle 64
.EXAMPLE
    .\SQLMap.Cli.ps1 -InputFile .\servers.txt -SqlConnect -Credential (Get-Credential CONTOSO\dbaadmin)
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

    # Scan
    [ValidateSet('Ping', 'Tcp', 'Browser', 'Registry', 'Service', 'SqlConnect')]
    [string[]]$Probe = @('Ping', 'Tcp', 'Browser', 'Registry', 'Service'),
    [switch]$SqlConnect,
    [int[]]$TcpPort = @(1433),
    [int]$TimeoutMs = 1500,
    [int]$Throttle = 32,
    [int]$HostTimeoutSec = 300,
    [pscredential]$Credential,
    [pscredential]$SqlCredential,

    # Output
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Output'),
    [ValidateSet('Html', 'Json', 'Csv')]
    [string[]]$Format = @('Html', 'Json', 'Csv'),
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\SQLMap\SQLMap.psd1') -Force

$runFolder = Join-Path $OutputPath ('SQLMap_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$null = New-Item -Path $runFolder -ItemType Directory -Force
$logPath = Join-Path $runFolder 'SQLMap.log'

$scanParams = @{}
$cliOnly = 'OutputPath', 'Format', 'OpenReport'
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -notin $cliOnly -and $k -notin [System.Management.Automation.PSCmdlet]::CommonParameters) { $scanParams[$k] = $PSBoundParameters[$k] }
}
$scanParams.LogPath = $logPath

Write-Host 'SQLMap - SQL Server discovery' -ForegroundColor Cyan

$scan = Invoke-SQLMapScan @scanParams
$files = $scan | Export-SQLMapReport -Path $runFolder -Format $Format

$s = $scan.Summary
Write-Host ''
Write-Host ("Hosts scanned: {0}  |  with SQL: {1}  |  no SQL: {2}  |  inconclusive: {3}  |  unreachable: {4}  |  failed: {5}" -f `
    $s.Targets, $s.HostsWithSql, $s.HostsNoSql, $s.HostsInconclusive, $s.HostsUnreachable, $s.HostsFailed) -ForegroundColor Cyan
if ($s.HostsAccessDenied) {
    Write-Host ("{0} host(s) not verified because access was denied to the registry and services: run the scan with an account " +
                "that is local administrator on the targets (-Credential)." -f $s.HostsAccessDenied) -ForegroundColor DarkYellow
}
$byType = ($s.InstancesByType.PSObject.Properties | ForEach-Object { "$($_.Value) $($_.Name)" }) -join ', '
Write-Host ("Instances: {0} ({1})  |  engines running: {2}  |  out of support: {3}  |  behind latest update: {4} ({5} missing security updates)  |  duration: {6}s" -f `
    $s.Instances, $byType, $s.EnginesRunning, $s.EnginesOutOfSupport, $s.EnginesBehindLatest, $s.EnginesMissingSecurityUpdate, $scan.DurationSec) -ForegroundColor Cyan
$refDate = $scan.Parameters.BuildReference
$refMaxAge = if ($scan.Parameters.BuildReferenceMaxAgeDays) { [int]$scan.Parameters.BuildReferenceMaxAgeDays } else { 30 }
if (-not $refDate) { Write-Host 'No build reference file: run Update-SQLMapBuildReference to see update levels.' -ForegroundColor DarkYellow }
elseif (((Get-Date) - [datetime]$refDate).TotalDays -gt $refMaxAge) { Write-Host "Build reference is from $refDate (older than $refMaxAge days). Run Update-SQLMapBuildReference for current update data." -ForegroundColor DarkYellow }

if ($scan.Instances) {
    $scan.Instances |
        Sort-Object SqlInstance, ServiceType |
        Format-Table -AutoSize -Property SqlInstance, ServiceType, ProductName, Version,
            @{ n = 'Level'; e = { $_.UpdateLevel } },
            @{ n = 'Latest'; e = { $p = $_   # inside switch, $_ is the switch value
                switch ($p.PatchStatus) {
                    'Behind' { "$($p.LatestUpdate) ($($p.UpdatesBehind) behind)" }
                    'Security update missing' { "$($p.LatestUpdate) ($($p.UpdatesBehind) behind, SECURITY UPDATE MISSING)" }
                    'Latest' { 'Yes' }
                    'Not covered' { 'Not in reference' }
                    default { $p.PatchStatus } } } },
            @{ n = 'State'; e = { if ($_.IsRunning -eq $true) { 'Running' } elseif ($_.IsRunning -eq $false) { 'Stopped' } else { '?' } } },
            SupportStatus, @{ n = 'Components'; e = { $_.Components -join ', ' } } |
        Out-String -Width 220 | Write-Host
}

Write-Host 'Output:' -ForegroundColor Cyan
foreach ($p in $files.PSObject.Properties) { if ($p.Value) { Write-Host "  $($p.Value)" } }
Write-Host "  $logPath"

if ($OpenReport -and $files.Html) { Invoke-Item $files.Html }
