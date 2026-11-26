@{
    RootModule           = 'SQLMap.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6f3c2a7e-0b8d-4c55-9a51-2f1e8d7c4b10'
    Author               = 'Fabiano Amorim'
    CompanyName          = 'Power Tuning'
    Copyright            = '(c) Power Tuning. All rights reserved.'
    Description          = 'SQLMap - discovers SQL Server services (Engine, SSAS, SSRS, PBIRS) on a network and produces HTML/JSON/CSV reports.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredModules      = @()
    FunctionsToExport    = @(
        'Find-SQLMapTarget',
        'Invoke-SQLMapComputerScan',
        'Invoke-SQLMapScan',
        'Export-SQLMapReport',
        'Import-SQLMapScan',
        'Update-SQLMapBuildReference'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('SQLServer', 'Discovery', 'Inventory', 'DBA')
        }
    }
}
