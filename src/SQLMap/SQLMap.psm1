#Requires -Version 5.1

$script:ModuleRoot         = $PSScriptRoot
$script:ModuleManifestPath = Join-Path $PSScriptRoot 'SQLMap.psd1'
$script:ModuleVersion      = (Import-PowerShellDataFile -Path $script:ModuleManifestPath).ModuleVersion

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
    }
}

# Product catalog (versions + Microsoft lifecycle dates), loaded once per session/runspace
$script:SqlProducts = Get-Content -Path (Join-Path $PSScriptRoot 'Data\SqlProducts.json') -Raw | ConvertFrom-Json

Export-ModuleMember -Function @(
    'Find-SQLMapTarget',
    'Invoke-SQLMapComputerScan',
    'Invoke-SQLMapScan',
    'Export-SQLMapReport',
    'Import-SQLMapScan',
    'Update-SQLMapBuildReference'
)
