<#
.SYNOPSIS
    SQLMap Windows UI. Discovers SQL Server services on a network and writes HTML/JSON/CSV reports.
.DESCRIPTION
    Double-click SQLMap.cmd, or run:  powershell.exe -STA -File .\SQLMap.ps1
    For scripting/scheduling use SQLMap.Cli.ps1 instead.

    The console shows each startup step with the seconds since start (same as SQLSecReview), so a slow
    start shows where the time goes. Keep the console open while SQLMap runs: closing it closes the app.
#>
[CmdletBinding()]
param()

# WinForms needs a single-threaded apartment; relaunch if this host is MTA
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    & $exe -NoProfile -STA -File $PSCommandPath
    return
}

$ErrorActionPreference = 'Stop'
$startupWatch = [Diagnostics.Stopwatch]::StartNew()
$startupProgress = { param([string]$Text) Write-Host ('[{0,5:n1} s] {1}' -f $startupWatch.Elapsed.TotalSeconds, $Text) }.GetNewClosure()
try { $Host.UI.RawUI.WindowTitle = 'SQLMap' } catch { }

try {
    & $startupProgress 'Starting SQLMap...'
    & $startupProgress 'Loading Windows Forms...'
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    # Crisp text on high-DPI screens (must run before any window is created)
    Add-Type -Namespace SQLMap -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction SilentlyContinue
    try { [void][SQLMap.Native]::SetProcessDPIAware() } catch { }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    & $startupProgress 'Loading the SQLMap module...'
    $modulePath = Join-Path $PSScriptRoot 'src\SQLMap\SQLMap.psd1'
    Import-Module $modulePath -Force

    # Build reference used for the patch level: its date, and a reminder when it is past its 30-day window
    $ref = & (Get-Module SQLMap) { Get-SQLMapBuildReference }
    if ($ref.Available) {
        $age = [int]((Get-Date).ToUniversalTime() - $ref.RetrievedUtc.ToUniversalTime()).TotalDays
        & $startupProgress ("Build reference retrieved {0} ({1} day(s) old, {2} builds)." -f $ref.LastUpdated, $age, (@($ref.Products.Values | ForEach-Object { $_ }).Count))
        if ($age -gt $ref.MaxAgeDays) {
            Write-Host "          The build reference is older than $($ref.MaxAgeDays) days: run Update-SQLMapBuildReference for current update levels." -ForegroundColor DarkYellow
        }
    }
    else { Write-Host '          No build reference file: run Update-SQLMapBuildReference to see update levels.' -ForegroundColor DarkYellow }

    & $startupProgress 'Loading the window scripts...'
    . (Join-Path $PSScriptRoot 'src\SQLMapUI\SQLMap.UI.ps1')

    $ui = New-SQLMapMainForm -ModulePath $modulePath -DefaultOutput (Join-Path $PSScriptRoot 'Output') `
        -IconPath (Join-Path $PSScriptRoot 'assets\SQLMap.ico') -StartupProgress $startupProgress
    [void]$ui.Form.ShowDialog()
    $ui.Form.Dispose()
}
catch {
    $msg = "SQLMap could not start:`r`n`r`n$($_.Exception.Message)"
    Write-Host $msg -ForegroundColor Red
    try { [void][System.Windows.Forms.MessageBox]::Show($msg, 'SQLMap', 'OK', 'Error') } catch { }
}
