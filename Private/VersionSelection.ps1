function Assert-VersionBandSelectors {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Selectors
    )

    foreach ($selectorValue in $Selectors) {
        $selector = $selectorValue.Trim()
        if ($selector -notmatch '^\d+$' -and
            $selector -notmatch '^\d+\.\d+$' -and
            $selector -notmatch '^\d+\.\d+\.\d+xx$' -and
            $selector -notmatch '^\d+\.\d+\.\d+(?:-[^\s]+)?$') {
            throw "Invalid version-band selector '$selectorValue'. Use forms such as 8, 8.0, 8.0.4xx, or 8.0.424."
        }
    }
}

function Test-VersionBandMatch {
    param(
        [Parameter(Mandatory = $true)]
        [object] $VersionInfo,

        [Parameter(Mandatory = $true)]
        [string] $SelectorValue
    )

    $selector = $SelectorValue.Trim()

    if ($selector -match '^(?<major>\d+)$') {
        return $VersionInfo.Major -eq [int] $Matches.major
    }

    if ($selector -match '^(?<major>\d+)\.(?<minor>\d+)$') {
        return $VersionInfo.Major -eq [int] $Matches.major -and
            $VersionInfo.Minor -eq [int] $Matches.minor
    }

    if ($selector -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<band>\d+)xx$') {
        return $VersionInfo.Major -eq [int] $Matches.major -and
            $VersionInfo.Minor -eq [int] $Matches.minor -and
            [int] [math]::Floor($VersionInfo.Patch / 100) -eq [int] $Matches.band
    }

    return $VersionInfo.Text -eq $selector
}

function Select-InstallationsByVersionBand {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Installations,

        [Parameter(Mandatory = $true)]
        [string[]] $Selectors
    )

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($installation in $Installations) {
        foreach ($selector in $Selectors) {
            if (Test-VersionBandMatch -VersionInfo $installation.VersionInfo -SelectorValue $selector) {
                $selected.Add($installation)
                break
            }
        }
    }

    return $selected.ToArray()
}
