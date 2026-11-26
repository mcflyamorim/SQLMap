function Find-SQLMapTarget {
    <#
    .SYNOPSIS
        Builds the list of computers to scan from one or more discovery sources.
    .DESCRIPTION
        Sources can be combined; results are de-duplicated by short name.
        With no source, the local computer is returned.

          -ComputerName       explicit names (srv, srv\inst and srv,port are accepted)
          -InputFile          .txt (one per line) or .csv (ComputerName/Name/Server/Host/SqlInstance column)
          -ActiveDirectory    enabled computer accounts (servers only unless -IncludeWorkstations), via ADSI (no RSAT needed)
          -SPN                every MSSQLSvc SPN registered in AD
          -IpRange            CIDR / ranges / single IPs
          -Broadcast          SQL Browser UDP broadcast on the local subnet (same as SSMS "Browse")
    .EXAMPLE
        Find-SQLMapTarget -ActiveDirectory -SPN -NameFilter 'SQL*'
    .EXAMPLE
        Find-SQLMapTarget -IpRange 10.0.1.0/24, 10.0.2.10-10.0.2.40
    #>
    [CmdletBinding()]
    param(
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
        [pscredential]$Credential
    )
    $all = New-Object System.Collections.Generic.List[object]
    $add = { param($items, $label) $n = 0; foreach ($i in $items) { $all.Add($i); $n++ }; Write-Verbose "Discovery ${label}: $n target(s)" }

    foreach ($c in $ComputerName) {
        if (-not [string]::IsNullOrWhiteSpace($c)) {
            $all.Add((New-SQLMapTarget -ComputerName (ConvertTo-SQLMapComputerName $c) -Source 'Manual'))
        }
    }
    if ($InputFile) { & $add (Get-SQLMapFileTarget -Path $InputFile) 'File' }
    $adHint = 'Check that this computer is in a domain, or pass -Domain (and -Credential for another domain).'
    if ($ActiveDirectory) {
        try {
            & $add (Get-SQLMapAdComputerTarget -Domain $Domain -SearchBase $SearchBase -NameFilter $NameFilter `
                    -IncludeWorkstations:$IncludeWorkstations -ActiveWithinDays $ActiveWithinDays -Credential $Credential) 'ActiveDirectory'
        }
        catch { throw "Active Directory computer discovery failed: $(Get-SQLMapErrorMessage $_) $adHint" }
    }
    if ($SPN) {
        try { & $add (Get-SQLMapSpnTarget -Domain $Domain -SearchBase $SearchBase -Credential $Credential) 'SPN' }
        catch { throw "SPN discovery failed: $(Get-SQLMapErrorMessage $_) $adHint" }
    }
    if ($IpRange) { & $add (Get-SQLMapIpRangeTarget -Range $IpRange) 'IPRange' }
    if ($Broadcast) { & $add (Get-SQLMapBroadcastTarget) 'Broadcast' }

    $noSource = -not ($ComputerName -or $InputFile -or $ActiveDirectory -or $SPN -or $IpRange -or $Broadcast)
    if ($noSource) { $all.Add((New-SQLMapTarget -ComputerName $env:COMPUTERNAME -Source 'Local')) }

    Merge-SQLMapTarget -Target $all.ToArray()
}
