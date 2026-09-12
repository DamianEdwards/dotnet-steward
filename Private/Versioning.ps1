function New-SdkVersionInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    if ($Text -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<prerelease>.+))?$') {
        throw "Unsupported .NET version format: '$Text'."
    }

    $major = [int] $Matches.major
    $minor = [int] $Matches.minor
    $patch = [int] $Matches.patch
    $prerelease = $null
    if ($Matches.ContainsKey('prerelease')) {
        $prerelease = $Matches.prerelease
    }

    [pscustomobject] @{
        Text           = $Text
        Core           = [version]::Parse("$major.$minor.$patch")
        Major          = $major
        Minor          = $minor
        Patch          = $patch
        Prerelease     = $prerelease
        IsStable       = [string]::IsNullOrEmpty($prerelease)
        Channel        = "$major.$minor"
        FeatureBand    = [int] ([math]::Floor($patch / 100) * 100)
        FeatureBandKey = ('{0}.{1}.{2}xx' -f $major, $minor, [int] [math]::Floor($patch / 100))
    }
}

function Compare-SdkVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Left,

        [Parameter(Mandatory = $true)]
        [object] $Right
    )

    $comparison = $Left.Core.CompareTo($Right.Core)
    if ($comparison -ne 0) {
        return $comparison
    }

    if ($Left.IsStable -and -not $Right.IsStable) {
        return 1
    }

    if (-not $Left.IsStable -and $Right.IsStable) {
        return -1
    }

    $leftIdentifiers = @([string] $Left.Prerelease -split '\.')
    $rightIdentifiers = @([string] $Right.Prerelease -split '\.')
    $identifierCount = [math]::Min($leftIdentifiers.Count, $rightIdentifiers.Count)

    for ($index = 0; $index -lt $identifierCount; $index++) {
        $leftIdentifier = $leftIdentifiers[$index]
        $rightIdentifier = $rightIdentifiers[$index]
        if ($leftIdentifier -ceq $rightIdentifier) {
            continue
        }

        $leftIsNumeric = $leftIdentifier -match '^\d+$'
        $rightIsNumeric = $rightIdentifier -match '^\d+$'
        if ($leftIsNumeric -and -not $rightIsNumeric) {
            return -1
        }
        if (-not $leftIsNumeric -and $rightIsNumeric) {
            return 1
        }

        if ($leftIsNumeric) {
            $leftNumber = $leftIdentifier.TrimStart('0')
            $rightNumber = $rightIdentifier.TrimStart('0')
            if ($leftNumber.Length -eq 0) {
                $leftNumber = '0'
            }
            if ($rightNumber.Length -eq 0) {
                $rightNumber = '0'
            }

            if ($leftNumber.Length -ne $rightNumber.Length) {
                return [math]::Sign($leftNumber.Length - $rightNumber.Length)
            }

            $comparison = [string]::CompareOrdinal($leftNumber, $rightNumber)
        }
        else {
            $comparison = [string]::CompareOrdinal($leftIdentifier, $rightIdentifier)
        }

        if ($comparison -ne 0) {
            return $comparison
        }
    }

    return [math]::Sign($leftIdentifiers.Count - $rightIdentifiers.Count)
}

function Test-PrereleaseTargetAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [object] $CurrentVersionInfo,

        [Parameter(Mandatory = $true)]
        [object] $TargetVersionInfo,

        [Parameter(Mandatory = $true)]
        [bool] $AllowPreview
    )

    return $TargetVersionInfo.IsStable -or -not $CurrentVersionInfo.IsStable -or $AllowPreview
}

function Get-LatestVersionedItem {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Items
    )

    $latest = $null
    foreach ($item in $Items) {
        if ($null -eq $latest -or (Compare-SdkVersion -Left $item.VersionInfo -Right $latest.VersionInfo) -gt 0) {
            $latest = $item
        }
    }

    return $latest
}

function Sort-UpdateCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Candidates
    )

    $sorted = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $Candidates) {
        $insertAt = $sorted.Count
        for ($index = 0; $index -lt $sorted.Count; $index++) {
            if ((Compare-SdkVersion -Left $candidate.TargetVersionInfo `
                -Right $sorted[$index].TargetVersionInfo) -lt 0) {
                $insertAt = $index
                break
            }
        }
        $sorted.Insert($insertAt, $candidate)
    }

    return $sorted.ToArray()
}
