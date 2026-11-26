function Import-SQLMapScan {
    <#
    .SYNOPSIS
        Loads a scan saved by Export-SQLMapReport (-Format Json).
    .EXAMPLE
        Import-SQLMapScan .\Output\SQLMap_20261125_101500\SQLMap.json | Export-SQLMapReport -Path .\Output\rerender -Format Html
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path
    )
    process {
        $scan = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $scan.PSObject.Properties['SchemaVersion'] -or $scan.Tool -ne 'SQLMap') {
            throw "'$Path' is not a SQLMap scan file."
        }
        # Scans saved before InstanceTypes/EngineCount existed: derive them from the scan's instances
        foreach ($h in @($scan.Hosts)) {
            if (-not $h -or $h.PSObject.Properties['InstanceTypes']) { continue }
            $mine = @(@($scan.Instances) | Where-Object { $_ -and $_.ComputerName -eq $h.ComputerName })
            $types = Get-SQLMapInstanceTypeText $mine
            $h | Add-Member -NotePropertyName InstanceTypes -NotePropertyValue $(if ($types) { $types } else { $null })
            $h | Add-Member -NotePropertyName EngineCount -NotePropertyValue @($mine | Where-Object { $_.ServiceType -eq 'Engine' }).Count
        }
        $scan
    }
}
