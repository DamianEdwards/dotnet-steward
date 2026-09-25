function Assert-DotNetStewardPlatform {
    if ($env:OS -ne 'Windows_NT') {
        throw 'DotNetSteward manages official Windows EXE installers and can only run on Windows.'
    }

    if ($PSVersionTable.PSVersion -lt [version] '5.1') {
        throw 'PowerShell 5.1 or later is required.'
    }
}

function Get-NativeDotNetArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    switch -Regex ($architecture) {
        '^(?i:AMD64)$' { return 'x64' }
        '^(?i:ARM64)$' { return 'arm64' }
        '^(?i:X86)$' { return 'x86' }
        default {
            throw "The native Windows architecture '$architecture' is not supported."
        }
    }
}

function Assert-DotNetChannels {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Channels
    )

    foreach ($channel in $Channels) {
        if ($channel -notmatch '^\d+\.\d+$') {
            throw "Invalid .NET channel '$channel'. Use a major/minor channel such as 8.0."
        }
    }
}

function Assert-SdkFeatureBands {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $VersionBands
    )

    foreach ($versionBand in $VersionBands) {
        if ($versionBand -notmatch '^\d+\.\d+\.\d+xx$') {
            throw "Invalid SDK feature band '$versionBand'. Use a feature band such as 8.0.4xx."
        }
    }
}

function Assert-ExactDotNetVersions {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Versions
    )

    foreach ($version in $Versions) {
        [void] (New-SdkVersionInfo -Text $version)
    }
}

function Get-RequestedChannels {
    param(
        [string[]] $Channels,
        [string[]] $VersionBands,
        [string[]] $Versions
    )

    $requested = New-Object System.Collections.Generic.List[string]
    foreach ($channel in @($Channels)) {
        if ([string]::IsNullOrWhiteSpace($channel)) {
            continue
        }
        if (-not $requested.Contains($channel)) {
            $requested.Add($channel)
        }
    }
    foreach ($versionBand in @($VersionBands)) {
        if ([string]::IsNullOrWhiteSpace($versionBand)) {
            continue
        }
        $versionInfo = New-SdkVersionInfo -Text (
            $versionBand.Substring(0, $versionBand.Length - 2) + '00'
        )
        if (-not $requested.Contains($versionInfo.Channel)) {
            $requested.Add($versionInfo.Channel)
        }
    }
    foreach ($version in @($Versions)) {
        if ([string]::IsNullOrWhiteSpace($version)) {
            continue
        }
        $versionInfo = New-SdkVersionInfo -Text $version
        if (-not $requested.Contains($versionInfo.Channel)) {
            $requested.Add($versionInfo.Channel)
        }
        if ($versionInfo.Major -eq 1 -and $versionInfo.Minor -eq 0 -and
            -not $requested.Contains('1.1')) {
            $requested.Add('1.1')
        }
    }

    return $requested.ToArray()
}

function New-AvailableRelease {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Installer,

        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry,

        [Parameter(Mandatory = $true)]
        [string] $Architecture,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Sdk', 'Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string] $ProductType
    )

    [pscustomobject] @{
        PSTypeName = 'DotNetSteward.AvailableRelease'
        ProductType = $ProductType
        ProductLabel = Get-DotNetProductLabel -ProductType $ProductType
        Version = $Installer.Version
        VersionInfo = $Installer.VersionInfo
        Channel = [string] $ChannelEntry.PSObject.Properties[
            'channel-version'
        ].Value
        FeatureBand = if ($ProductType -eq 'Sdk') {
            $Installer.VersionInfo.FeatureBandKey
        }
        else {
            $null
        }
        Architecture = $Architecture
        Rid = $Installer.Rid
        IsPrerelease = -not $Installer.VersionInfo.IsStable
        SupportPhase = Get-SupportPhase -ChannelEntry $ChannelEntry
        ReleaseType = Get-ReleaseType -ChannelEntry $ChannelEntry
        Url = $Installer.Url
        Hash = $Installer.Hash
        HashAlgorithm = $Installer.HashAlgorithm
    }
}

function Sort-AvailableReleases {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Releases
    )

    $sorted = New-Object System.Collections.Generic.List[object]
    foreach ($release in $Releases) {
        $insertAt = $sorted.Count
        for ($index = 0; $index -lt $sorted.Count; $index++) {
            $comparison = Compare-SdkVersion -Left $release.VersionInfo `
                -Right $sorted[$index].VersionInfo
            if ($comparison -gt 0) {
                $insertAt = $index
                break
            }
            if ($comparison -eq 0) {
                $productComparison = [string]::CompareOrdinal(
                    $release.ProductType,
                    $sorted[$index].ProductType
                )
                if ($productComparison -lt 0 -or
                    ($productComparison -eq 0 -and
                    [string]::CompareOrdinal(
                        $release.Architecture,
                        $sorted[$index].Architecture
                    ) -lt 0)) {
                    $insertAt = $index
                    break
                }
            }
        }
        $sorted.Insert($insertAt, $release)
    }

    return $sorted.ToArray()
}

function Select-AvailableReleases {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Releases,

        [string[]] $VersionBands,
        [string[]] $Versions,

        [Parameter(Mandatory = $true)]
        [bool] $IncludePreview,

        [Parameter(Mandatory = $true)]
        [bool] $AllVersions
    )

    $selected = @($Releases)
    $requestedVersions = @($Versions | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    $requestedVersionBands = @($VersionBands | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($requestedVersions.Count -gt 0) {
        $selected = @($selected | Where-Object {
            $requestedVersions -contains $_.Version
        })
    }
    elseif ($requestedVersionBands.Count -gt 0) {
        $selected = @($selected | Where-Object {
            $requestedVersionBands -contains $_.VersionInfo.FeatureBandKey
        })
    }

    if ($requestedVersions.Count -eq 0 -and -not $IncludePreview) {
        $selected = @($selected | Where-Object { -not $_.IsPrerelease })
    }

    $unique = @{}
    foreach ($release in $selected) {
        $keyParts = @(
            $release.ProductType
            $release.Version
            $release.Rid
        )
        if ($requestedVersions.Count -eq 0) {
            $keyParts += $release.Channel
        }
        $key = $keyParts -join '|'
        if (-not $unique.ContainsKey($key)) {
            $unique[$key] = $release
        }
    }
    $selected = @($unique.Values)

    if ($AllVersions -or $requestedVersions.Count -gt 0) {
        return Sort-AvailableReleases -Releases $selected
    }

    $latestByGroup = @{}
    foreach ($release in $selected) {
        $groupParts = @(
            $release.ProductType
            $release.Channel
            $release.Rid
        )
        if ($requestedVersionBands.Count -gt 0) {
            $groupParts += $release.FeatureBand
        }
        $groupKey = $groupParts -join '|'
        if (-not $latestByGroup.ContainsKey($groupKey) -or
            (Compare-SdkVersion -Left $release.VersionInfo `
                -Right $latestByGroup[$groupKey].VersionInfo) -gt 0) {
            $latestByGroup[$groupKey] = $release
        }
    }

    return Sort-AvailableReleases -Releases @($latestByGroup.Values)
}

function Get-AvailableSdkReleases {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $ReleaseIndex,

        [Parameter(Mandatory = $true)]
        [string[]] $Architectures,

        [string[]] $Channels,
        [string[]] $VersionBands,
        [string[]] $Versions,

        [Parameter(Mandatory = $true)]
        [bool] $IncludePreview,

        [Parameter(Mandatory = $true)]
        [bool] $AllVersions
    )

    $requestedChannels = @(Get-RequestedChannels -Channels $Channels `
        -VersionBands $VersionBands -Versions $Versions)
    $metadataCache = @{}
    $available = New-Object System.Collections.Generic.List[object]

    foreach ($channelEntry in $ReleaseIndex) {
        $channelProperty = $channelEntry.PSObject.Properties['channel-version']
        if ($null -eq $channelProperty) {
            continue
        }
        $channel = [string] $channelProperty.Value
        if ($requestedChannels.Count -gt 0 -and
            $requestedChannels -notcontains $channel) {
            continue
        }

        foreach ($architecture in $Architectures) {
            $installers = @(Get-ChannelSdkInstallers -ChannelEntry $channelEntry `
                -Rid "win-$architecture" -MetadataCache $metadataCache)
            foreach ($installer in $installers) {
                $available.Add((New-AvailableRelease -Installer $installer `
                    -ChannelEntry $channelEntry -Architecture $architecture `
                    -ProductType Sdk))
            }
        }
    }

    return Select-AvailableReleases -Releases $available.ToArray() `
        -VersionBands $VersionBands -Versions $Versions `
        -IncludePreview $IncludePreview -AllVersions $AllVersions
}

function Get-AvailableRuntimeReleases {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $ReleaseIndex,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string[]] $ProductTypes,

        [Parameter(Mandatory = $true)]
        [string[]] $Architectures,

        [string[]] $Channels,
        [string[]] $Versions,

        [Parameter(Mandatory = $true)]
        [bool] $IncludePreview,

        [Parameter(Mandatory = $true)]
        [bool] $AllVersions
    )

    $requestedChannels = @(Get-RequestedChannels -Channels $Channels `
        -Versions $Versions)
    $metadataCache = @{}
    $available = New-Object System.Collections.Generic.List[object]

    foreach ($channelEntry in $ReleaseIndex) {
        $channelProperty = $channelEntry.PSObject.Properties['channel-version']
        if ($null -eq $channelProperty) {
            continue
        }
        $channel = [string] $channelProperty.Value
        if ($requestedChannels.Count -gt 0 -and
            $requestedChannels -notcontains $channel) {
            continue
        }

        foreach ($architecture in $Architectures) {
            foreach ($productType in $ProductTypes) {
                $installers = @(Get-ChannelRuntimeInstallers `
                    -ChannelEntry $channelEntry -Rid "win-$architecture" `
                    -ProductType $productType -MetadataCache $metadataCache)
                foreach ($installer in $installers) {
                    $available.Add((New-AvailableRelease -Installer $installer `
                        -ChannelEntry $channelEntry -Architecture $architecture `
                        -ProductType $productType))
                }
            }
        }
    }

    return Select-AvailableReleases -Releases $available.ToArray() `
        -Versions $Versions -IncludePreview $IncludePreview `
        -AllVersions $AllVersions
}

function ConvertTo-DotNetInstallCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Releases
    )

    foreach ($release in $Releases) {
        [pscustomobject] @{
            ProductType = $release.ProductType
            ProductLabel = $release.ProductLabel
            Architecture = $release.Architecture
            Band = if ($release.ProductType -eq 'Sdk') {
                $release.FeatureBand
            }
            else {
                $release.Channel
            }
            CurrentVersion = $null
            InstalledVersions = @()
            TargetVersion = $release.Version
            TargetVersionInfo = $release.VersionInfo
            Channel = $release.Channel
            SupportPhase = $release.SupportPhase
            Url = $release.Url
            Hash = $release.Hash
            HashAlgorithm = $release.HashAlgorithm
            Rid = $release.Rid
        }
    }
}

function Assert-RequestedReleasesResolved {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Releases,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Channel', 'VersionBand', 'Version')]
        [string] $SelectorKind,

        [Parameter(Mandatory = $true)]
        [string[]] $Selectors,

        [Parameter(Mandatory = $true)]
        [string[]] $Architectures,

        [Parameter(Mandatory = $true)]
        [string[]] $ProductTypes
    )

    foreach ($productType in $ProductTypes) {
        foreach ($architecture in $Architectures) {
            foreach ($selector in $Selectors) {
                $match = @($Releases | Where-Object {
                    $release = $_
                    if ($release.ProductType -ne $productType -or
                        $release.Architecture -ne $architecture) {
                        return $false
                    }

                    switch ($SelectorKind) {
                        'Channel' { return $release.Channel -eq $selector }
                        'VersionBand' {
                            return $release.FeatureBand -eq $selector
                        }
                        'Version' { return $release.Version -eq $selector }
                    }
                })
                if ($match.Count -eq 0) {
                    $label = Get-DotNetProductLabel -ProductType $productType
                    throw "No official $architecture $label EXE installer was found for $SelectorKind '$selector'."
                }
            }
        }
    }
}
