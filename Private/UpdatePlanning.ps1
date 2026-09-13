function Get-UpdateCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $InstalledSdks,

        [Parameter(Mandatory = $true)]
        [object[]] $ReleaseIndex,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Patch', 'FeatureBand', 'Major')]
        [string] $Scope,

        [Parameter(Mandatory = $true)]
        [bool] $AllowPreview
    )

    $channelInstallerCache = @{}
    $candidates = New-Object System.Collections.Generic.List[object]

    $groups = @{}
    foreach ($sdk in $InstalledSdks) {
        switch ($Scope) {
            'Patch' {
                $key = "$($sdk.Rid)|$($sdk.VersionInfo.FeatureBandKey)"
            }
            'FeatureBand' {
                $key = "$($sdk.Rid)|$($sdk.VersionInfo.Channel)"
            }
            'Major' {
                $key = $sdk.Rid
            }
        }

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.Generic.List[object]
        }
        $groups[$key].Add($sdk)
    }

    foreach ($key in @($groups.Keys | Sort-Object)) {
        $installedGroup = $groups[$key].ToArray()
        $current = Get-LatestVersionedItem -Items $installedGroup
        $rid = $current.Rid
        $architecture = $current.Architecture
        $channelEntry = $null
        $target = $null

        if ($Scope -eq 'Major') {
            $latestIndexSdk = $null
            foreach ($entry in $ReleaseIndex) {
                $latestSdkProperty = $entry.PSObject.Properties['latest-sdk']
                if ($null -eq $latestSdkProperty) {
                    continue
                }

                try {
                    $versionInfo = New-SdkVersionInfo -Text ([string] $latestSdkProperty.Value)
                }
                catch {
                    continue
                }

                if (-not (Test-PrereleaseTargetAllowed -CurrentVersionInfo $current.VersionInfo `
                    -TargetVersionInfo $versionInfo -AllowPreview $AllowPreview)) {
                    continue
                }

                if ($null -eq $latestIndexSdk -or
                    (Compare-SdkVersion -Left $versionInfo -Right $latestIndexSdk) -gt 0) {
                    $latestIndexSdk = $versionInfo
                    $channelEntry = $entry
                }
            }

            if ($null -eq $latestIndexSdk -or $null -eq $channelEntry) {
                throw "Microsoft's release index did not contain an eligible SDK release."
            }

            $channel = [string] $channelEntry.PSObject.Properties['channel-version'].Value
            $cacheKey = "$channel|$rid"
            if (-not $channelInstallerCache.ContainsKey($cacheKey)) {
                $channelInstallerCache[$cacheKey] = @(
                    Get-ChannelSdkInstallers -ChannelEntry $channelEntry -Rid $rid
                )
            }
            $target = $channelInstallerCache[$cacheKey] |
                Where-Object Version -eq $latestIndexSdk.Text |
                Select-Object -First 1
            $band = 'selected SDKs'
        }
        else {
            $channel = $current.VersionInfo.Channel
            $channelEntry = Get-ChannelIndexEntry -ReleaseIndex $ReleaseIndex -Channel $channel
            if ($null -eq $channelEntry) {
                Write-Warning "No official release metadata was found for installed SDK channel $channel."
                continue
            }

            $cacheKey = "$channel|$rid"
            if (-not $channelInstallerCache.ContainsKey($cacheKey)) {
                $channelInstallerCache[$cacheKey] = @(
                    Get-ChannelSdkInstallers -ChannelEntry $channelEntry -Rid $rid
                )
            }

            $available = @($channelInstallerCache[$cacheKey])
            if ($Scope -eq 'Patch') {
                $available = @($available | Where-Object {
                    $_.VersionInfo.FeatureBandKey -eq $current.VersionInfo.FeatureBandKey
                })
                $band = $current.VersionInfo.FeatureBandKey
            }
            else {
                $band = $current.VersionInfo.Channel
            }
            $available = @($available | Where-Object {
                Test-PrereleaseTargetAllowed -CurrentVersionInfo $current.VersionInfo `
                    -TargetVersionInfo $_.VersionInfo -AllowPreview $AllowPreview
            })

            if ($available.Count -gt 0) {
                $target = Get-LatestVersionedItem -Items $available
            }
        }

        if ($null -eq $target) {
            Write-Warning "No eligible $rid EXE installer was found for SDK band $band."
            continue
        }

        if ((Compare-SdkVersion -Left $target.VersionInfo -Right $current.VersionInfo) -le 0) {
            continue
        }

        $installedVersionTexts = @()
        foreach ($installedSdk in $installedGroup) {
            $installedVersionTexts += $installedSdk.Version
        }
        $candidates.Add([pscustomobject] @{
            ProductType = 'Sdk'
            ProductLabel = '.NET SDK'
            Architecture = $architecture
            Band = $band
            CurrentVersion = $current.Version
            InstalledVersions = $installedVersionTexts
            TargetVersion = $target.Version
            TargetVersionInfo = $target.VersionInfo
            Channel = $channel
            SupportPhase = Get-SupportPhase -ChannelEntry $channelEntry
            Url = $target.Url
            Hash = $target.Hash
            HashAlgorithm = $target.HashAlgorithm
            Rid = $target.Rid
        })
    }

    return $candidates.ToArray()
}

function Get-RuntimeUpdateCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $InstalledRuntimes,

        [Parameter(Mandatory = $true)]
        [object[]] $ReleaseIndex,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Patch', 'Major')]
        [string] $Scope,

        [Parameter(Mandatory = $true)]
        [bool] $AllowPreview
    )

    $channelInstallerCache = @{}
    $candidates = New-Object System.Collections.Generic.List[object]
    $groups = @{}

    foreach ($runtime in $InstalledRuntimes) {
        if ($Scope -eq 'Major') {
            $key = "$($runtime.ProductType)|$($runtime.Rid)"
        }
        else {
            $key = "$($runtime.ProductType)|$($runtime.Rid)|$($runtime.VersionInfo.Channel)"
        }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.Generic.List[object]
        }
        $groups[$key].Add($runtime)
    }

    foreach ($key in @($groups.Keys | Sort-Object)) {
        $installedGroup = $groups[$key].ToArray()
        $current = Get-LatestVersionedItem -Items $installedGroup
        $productType = $current.ProductType
        $productLabel = Get-DotNetProductLabel -ProductType $productType
        $rid = $current.Rid
        $channelEntry = $null
        $target = $null

        if ($Scope -eq 'Major') {
            $latestIndexRuntime = $null
            foreach ($entry in $ReleaseIndex) {
                $latestRuntimeProperty = $entry.PSObject.Properties['latest-runtime']
                if ($null -eq $latestRuntimeProperty) {
                    continue
                }

                try {
                    $versionInfo = New-SdkVersionInfo -Text ([string] $latestRuntimeProperty.Value)
                }
                catch {
                    continue
                }
                if (-not (Test-PrereleaseTargetAllowed -CurrentVersionInfo $current.VersionInfo `
                    -TargetVersionInfo $versionInfo -AllowPreview $AllowPreview)) {
                    continue
                }

                if ($null -eq $latestIndexRuntime -or
                    (Compare-SdkVersion -Left $versionInfo -Right $latestIndexRuntime) -gt 0) {
                    $latestIndexRuntime = $versionInfo
                    $channelEntry = $entry
                }
            }

            if ($null -eq $channelEntry) {
                throw "Microsoft's release index did not contain an eligible runtime release."
            }
            $channel = [string] $channelEntry.PSObject.Properties['channel-version'].Value
            $band = "all $productLabel installations"
        }
        else {
            $channel = $current.VersionInfo.Channel
            $band = $channel
            $channelEntry = Get-ChannelIndexEntry -ReleaseIndex $ReleaseIndex -Channel $channel
            if ($null -eq $channelEntry) {
                Write-Warning "No official release metadata was found for installed $productLabel channel $channel."
                continue
            }
        }

        $cacheKey = "$productType|$channel|$rid"
        if (-not $channelInstallerCache.ContainsKey($cacheKey)) {
            $channelInstallerCache[$cacheKey] = @(
                Get-ChannelRuntimeInstallers -ChannelEntry $channelEntry -Rid $rid `
                    -ProductType $productType
            )
        }
        $available = @($channelInstallerCache[$cacheKey] | Where-Object {
            Test-PrereleaseTargetAllowed -CurrentVersionInfo $current.VersionInfo `
                -TargetVersionInfo $_.VersionInfo -AllowPreview $AllowPreview
        })
        if ($available.Count -gt 0) {
            $target = Get-LatestVersionedItem -Items $available
        }

        if ($null -eq $target) {
            Write-Warning "No eligible $rid EXE installer was found for $productLabel channel $channel."
            continue
        }
        if ((Compare-SdkVersion -Left $target.VersionInfo -Right $current.VersionInfo) -le 0) {
            continue
        }

        $installedVersionTexts = @()
        foreach ($installedRuntime in $installedGroup) {
            $installedVersionTexts += $installedRuntime.Version
        }
        $candidates.Add([pscustomobject] @{
            ProductType = $productType
            ProductLabel = $productLabel
            Architecture = $current.Architecture
            Band = $band
            CurrentVersion = $current.Version
            InstalledVersions = $installedVersionTexts
            TargetVersion = $target.Version
            TargetVersionInfo = $target.VersionInfo
            Channel = $channel
            SupportPhase = Get-SupportPhase -ChannelEntry $channelEntry
            Url = $target.Url
            Hash = $target.Hash
            HashAlgorithm = $target.HashAlgorithm
            Rid = $target.Rid
        })
    }

    return $candidates.ToArray()
}
