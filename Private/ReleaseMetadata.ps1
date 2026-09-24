function Get-ReleaseIndex {
    Write-Host 'Checking Microsoft .NET release metadata...'
    $index = Invoke-RestMethod -Uri $script:ReleaseIndexUri -Method Get -Headers @{
        Accept = 'application/json'
        'User-Agent' = 'DotNetSteward'
    }

    $indexProperty = $index.PSObject.Properties['releases-index']
    if ($null -eq $indexProperty -or @($indexProperty.Value).Count -eq 0) {
        throw "Microsoft's release index did not contain any release channels."
    }

    return @($indexProperty.Value)
}

function Get-ChannelIndexEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $ReleaseIndex,

        [Parameter(Mandatory = $true)]
        [string] $Channel
    )

    foreach ($entry in $ReleaseIndex) {
        $channelProperty = $entry.PSObject.Properties['channel-version']
        if ($null -ne $channelProperty -and [string] $channelProperty.Value -eq $Channel) {
            return $entry
        }
    }

    return $null
}

function Get-ReleasesUri {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry
    )

    foreach ($propertyName in @('releases.json', 'patch-releases-info-uri')) {
        $property = $ChannelEntry.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string] $property.Value)) {
            $uri = [uri] $property.Value
            if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
                throw "Release metadata URI '$uri' is not an absolute HTTPS URI."
            }

            return $uri.AbsoluteUri
        }
    }

    $channel = [string] $ChannelEntry.PSObject.Properties['channel-version'].Value
    throw "The release-index entry for .NET $channel did not provide a releases metadata URI."
}

function Get-ChannelReleaseMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry,

        [AllowNull()]
        [hashtable] $Cache
    )

    $channel = [string] $ChannelEntry.PSObject.Properties['channel-version'].Value
    $releasesUri = Get-ReleasesUri -ChannelEntry $ChannelEntry
    if ($null -ne $Cache -and $Cache.ContainsKey($releasesUri)) {
        return $Cache[$releasesUri]
    }

    Write-Host "  Reading .NET $channel releases..."
    $metadata = Invoke-RestMethod -Uri $releasesUri -Method Get -Headers @{
        Accept = 'application/json'
        'User-Agent' = 'DotNetSteward'
    }

    $releasesProperty = $metadata.PSObject.Properties['releases']
    if ($null -eq $releasesProperty) {
        throw "Release metadata for .NET $channel did not contain a releases collection."
    }

    if ($null -ne $Cache) {
        $Cache[$releasesUri] = $metadata
    }

    return $metadata
}

function Get-ChannelSdkInstallers {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry,

        [Parameter(Mandatory = $true)]
        [string] $Rid,

        [AllowNull()]
        [hashtable] $MetadataCache
    )

    $metadata = Get-ChannelReleaseMetadata -ChannelEntry $ChannelEntry `
        -Cache $MetadataCache
    $releasesProperty = $metadata.PSObject.Properties['releases']

    $installerNames = @(
        "dotnet-sdk-$Rid.exe"
        "dotnet-dev-$Rid.exe"
    )
    $byVersion = @{}

    foreach ($release in @($releasesProperty.Value)) {
        $sdkObjects = New-Object System.Collections.Generic.List[object]
        $sdksProperty = $release.PSObject.Properties['sdks']
        if ($null -ne $sdksProperty) {
            foreach ($sdkValue in @($sdksProperty.Value)) {
                if ($null -ne $sdkValue) {
                    $sdkObjects.Add($sdkValue)
                }
            }
        }

        $sdkProperty = $release.PSObject.Properties['sdk']
        if ($null -ne $sdkProperty -and $null -ne $sdkProperty.Value) {
            $sdkObjects.Add($sdkProperty.Value)
        }

        foreach ($sdk in $sdkObjects) {
            $versionProperty = $sdk.PSObject.Properties['version']
            $filesProperty = $sdk.PSObject.Properties['files']
            if ($null -eq $versionProperty -or $null -eq $filesProperty) {
                continue
            }

            try {
                $versionInfo = New-SdkVersionInfo -Text ([string] $versionProperty.Value)
            }
            catch {
                continue
            }

            $matchingFiles = @($filesProperty.Value | Where-Object {
                $ridProperty = $_.PSObject.Properties['rid']
                $nameProperty = $_.PSObject.Properties['name']
                $null -ne $ridProperty -and $null -ne $nameProperty -and
                    [string] $ridProperty.Value -eq $Rid -and
                    $installerNames -contains [string] $nameProperty.Value
            })

            if ($matchingFiles.Count -eq 0) {
                continue
            }

            if ($matchingFiles.Count -gt 1) {
                throw "Release metadata contains multiple $Rid EXE installers for SDK $($versionInfo.Text)."
            }

            $file = $matchingFiles[0]
            $urlProperty = $file.PSObject.Properties['url']
            $hashProperty = $file.PSObject.Properties['hash']
            if ($null -eq $urlProperty -or $null -eq $hashProperty -or
                [string]::IsNullOrWhiteSpace([string] $hashProperty.Value)) {
                Write-Verbose "Skipping SDK $($versionInfo.Text) because its Windows installer metadata does not include a hash."
                continue
            }

            $url = [uri] ([string] $urlProperty.Value)
            $hash = ([string] $hashProperty.Value).ToUpperInvariant()
            if (-not $url.IsAbsoluteUri -or $url.Scheme -ne 'https') {
                throw "Installer URI '$url' for SDK $($versionInfo.Text) is not an absolute HTTPS URI."
            }

            if ($hash -notmatch '^(?:[0-9A-F]{64}|[0-9A-F]{128})$') {
                throw "Release metadata for SDK $($versionInfo.Text) has an invalid SHA-256 or SHA-512 hash."
            }

            $installer = [pscustomobject] @{
                Version = $versionInfo.Text
                VersionInfo = $versionInfo
                Rid = $Rid
                Url = $url.AbsoluteUri
                Hash = $hash
                HashAlgorithm = if ($hash.Length -eq 128) {
                    'SHA512'
                }
                else {
                    'SHA256'
                }
            }

            if ($byVersion.ContainsKey($versionInfo.Text)) {
                $existing = $byVersion[$versionInfo.Text]
                if ($existing.Url -ne $installer.Url -or $existing.Hash -ne $installer.Hash) {
                    throw "Release metadata contains conflicting installers for SDK $($versionInfo.Text)."
                }
            }
            else {
                $byVersion[$versionInfo.Text] = $installer
            }
        }
    }

    return @($byVersion.Values)
}

function Get-DotNetProductLabel {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Sdk', 'Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string] $ProductType
    )

    switch ($ProductType) {
        'Sdk' { return '.NET SDK' }
        'Runtime' { return '.NET Runtime' }
        'AspNetCoreRuntime' { return 'ASP.NET Core Runtime' }
        'WindowsDesktopRuntime' { return '.NET Windows Desktop Runtime' }
    }
}

function Get-ChannelRuntimeInstallers {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry,

        [Parameter(Mandatory = $true)]
        [string] $Rid,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string] $ProductType,

        [AllowNull()]
        [hashtable] $MetadataCache
    )

    $componentPropertyName = switch ($ProductType) {
        'Runtime' { 'runtime' }
        'AspNetCoreRuntime' { 'aspnetcore-runtime' }
        'WindowsDesktopRuntime' { 'windowsdesktop' }
    }
    $installerNames = switch ($ProductType) {
        'Runtime' {
            @(
                "dotnet-runtime-$Rid.exe"
                "dotnet-$Rid.exe"
            )
        }
        'AspNetCoreRuntime' { @("aspnetcore-runtime-$Rid.exe") }
        'WindowsDesktopRuntime' { @("windowsdesktop-runtime-$Rid.exe") }
    }
    $productLabel = Get-DotNetProductLabel -ProductType $ProductType
    $channel = [string] $ChannelEntry.PSObject.Properties['channel-version'].Value
    $metadata = Get-ChannelReleaseMetadata -ChannelEntry $ChannelEntry `
        -Cache $MetadataCache
    $releasesProperty = $metadata.PSObject.Properties['releases']

    $byVersion = @{}
    foreach ($release in @($releasesProperty.Value)) {
        $componentProperty = $release.PSObject.Properties[$componentPropertyName]
        if ($null -eq $componentProperty -or $null -eq $componentProperty.Value) {
            continue
        }

        $component = $componentProperty.Value
        $versionProperty = $component.PSObject.Properties['version']
        $filesProperty = $component.PSObject.Properties['files']
        if ($null -eq $versionProperty -or $null -eq $filesProperty) {
            continue
        }

        try {
            $versionInfo = New-SdkVersionInfo -Text ([string] $versionProperty.Value)
        }
        catch {
            continue
        }

        $matchingFiles = @($filesProperty.Value | Where-Object {
            $ridProperty = $_.PSObject.Properties['rid']
            $nameProperty = $_.PSObject.Properties['name']
            $null -ne $ridProperty -and $null -ne $nameProperty -and
                [string] $ridProperty.Value -eq $Rid -and
                $installerNames -contains [string] $nameProperty.Value
        })
        if ($matchingFiles.Count -eq 0) {
            continue
        }
        if ($matchingFiles.Count -gt 1) {
            throw "Release metadata contains multiple $Rid EXE installers for $productLabel $($versionInfo.Text)."
        }

        $file = $matchingFiles[0]
        $urlProperty = $file.PSObject.Properties['url']
        $hashProperty = $file.PSObject.Properties['hash']
        if ($null -eq $urlProperty -or $null -eq $hashProperty -or
            [string]::IsNullOrWhiteSpace([string] $hashProperty.Value)) {
            Write-Verbose "Skipping $productLabel $($versionInfo.Text) because its Windows installer metadata does not include a hash."
            continue
        }

        $url = [uri] ([string] $urlProperty.Value)
        $hash = ([string] $hashProperty.Value).ToUpperInvariant()
        if (-not $url.IsAbsoluteUri -or $url.Scheme -ne 'https') {
            throw "Installer URI '$url' for $productLabel $($versionInfo.Text) is not an absolute HTTPS URI."
        }
        if ($hash -notmatch '^(?:[0-9A-F]{64}|[0-9A-F]{128})$') {
            throw "Release metadata for $productLabel $($versionInfo.Text) has an invalid SHA-256 or SHA-512 hash."
        }

        $installer = [pscustomobject] @{
            ProductType = $ProductType
            ProductLabel = $productLabel
            Version = $versionInfo.Text
            VersionInfo = $versionInfo
            Rid = $Rid
            Url = $url.AbsoluteUri
            Hash = $hash
            HashAlgorithm = if ($hash.Length -eq 128) {
                'SHA512'
            }
            else {
                'SHA256'
            }
        }
        if ($byVersion.ContainsKey($versionInfo.Text)) {
            $existing = $byVersion[$versionInfo.Text]
            if ($existing.Url -ne $installer.Url -or $existing.Hash -ne $installer.Hash) {
                throw "Release metadata contains conflicting installers for $productLabel $($versionInfo.Text)."
            }
        }
        else {
            $byVersion[$versionInfo.Text] = $installer
        }
    }

    return @($byVersion.Values)
}

function Get-SupportPhase {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry
    )

    $property = $ChannelEntry.PSObject.Properties['support-phase']
    if ($null -eq $property) {
        return 'unknown'
    }

    return [string] $property.Value
}

function Get-ReleaseType {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry
    )

    $property = $ChannelEntry.PSObject.Properties['release-type']
    if ($null -eq $property -or
        [string]::IsNullOrWhiteSpace([string] $property.Value)) {
        return 'unknown'
    }

    return [string] $property.Value
}

function Get-ChannelSdkVersions {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ChannelEntry,

        [Parameter(Mandatory = $true)]
        [hashtable] $MetadataCache
    )

    $metadata = Get-ChannelReleaseMetadata -ChannelEntry $ChannelEntry -Cache $MetadataCache
    foreach ($release in @($metadata.releases)) {
        foreach ($propertyName in @('sdk', 'sdks')) {
            $property = $release.PSObject.Properties[$propertyName]
            if ($null -eq $property) {
                continue
            }
            foreach ($sdk in @($property.Value)) {
                if ($null -ne $sdk) {
                    New-SdkVersionInfo -Text ([string] $sdk.version)
                }
            }
        }
    }
}

function Get-InstallationSupportInfo {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Installation,

        [Parameter(Mandatory = $true)]
        [object[]] $ReleaseIndex,

        [Parameter(Mandatory = $true)]
        [hashtable] $MetadataCache
    )

    $version = $Installation.VersionInfo
    $channelEntry = Get-ChannelIndexEntry -ReleaseIndex $ReleaseIndex -Channel $version.Channel
    if ($Installation.ProductType -eq 'Sdk') {
        $possibleChannels = @(
            if ($null -ne $channelEntry) {
                $channelEntry
            }
            foreach ($entry in $ReleaseIndex) {
                $latestSdkProperty = $entry.PSObject.Properties['latest-sdk']
                if ($null -ne $latestSdkProperty -and $entry -ne $channelEntry) {
                    $latestSdk = New-SdkVersionInfo -Text ([string] $latestSdkProperty.Value)
                    if ($latestSdk.Channel -eq $version.Channel) {
                        $entry
                    }
                }
            }
        )

        # Early SDK versions can belong to a different runtime/catalog channel.
        if ($possibleChannels.Count -gt 1 -or $null -eq $channelEntry) {
            $channelEntry = $null
            foreach ($entry in $possibleChannels) {
                $versions = @(Get-ChannelSdkVersions -ChannelEntry $entry -MetadataCache $MetadataCache)
                if (@($versions | Where-Object Text -eq $version.Text).Count -gt 0) {
                    $channelEntry = $entry
                    break
                }
            }
        }
    }

    if ($null -eq $channelEntry) {
        throw "No official release channel was found for $($Installation.ProductType) $($version.Text)."
    }

    $channel = [string] $channelEntry.'channel-version'
    $phase = Get-SupportPhase -ChannelEntry $channelEntry
    if ($phase -notin @('active', 'maintenance', 'eol', 'preview', 'go-live')) {
        throw "Release metadata for .NET $channel has an unknown support phase '$phase'."
    }

    $endOfSupportDate = $null
    $endOfSupportProperty = $channelEntry.PSObject.Properties['eol-date']
    if ($null -ne $endOfSupportProperty -and
        -not [string]::IsNullOrWhiteSpace([string] $endOfSupportProperty.Value)) {
        $endOfSupportDate = [datetime]::ParseExact(
            [string] $endOfSupportProperty.Value,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }

    $latestPatch = $null
    if ($phase -eq 'eol' -or
        ($null -ne $endOfSupportDate -and $endOfSupportDate -lt [datetime]::Today)) {
        $status = ".NET $channel is out of support."
    }
    elseif ($phase -eq 'maintenance') {
        $status = ".NET $channel is going out of support soon."
    }
    else {
        if ($Installation.ProductType -eq 'Sdk') {
            $latestSdk = New-SdkVersionInfo -Text ([string] $channelEntry.'latest-sdk')
            if ($latestSdk.FeatureBandKey -eq $version.FeatureBandKey) {
                $latestPatch = $latestSdk
            }
            else {
                $versions = @(Get-ChannelSdkVersions -ChannelEntry $channelEntry -MetadataCache $MetadataCache)
                foreach ($candidate in $versions) {
                    if ($candidate.FeatureBandKey -eq $version.FeatureBandKey -and
                        ($null -eq $latestPatch -or
                            (Compare-SdkVersion -Left $candidate -Right $latestPatch) -gt 0)) {
                        $latestPatch = $candidate
                    }
                }
            }
        }
        else {
            $latestPatch = New-SdkVersionInfo -Text ([string] $channelEntry.'latest-runtime')
        }

        if ($null -eq $latestPatch) {
            throw "No official patch release was found for $($Installation.ProductType) $($version.Text)."
        }
        if ((Compare-SdkVersion -Left $latestPatch -Right $version) -gt 0) {
            $status = "Patch $($latestPatch.Text) is available."
        }
        else {
            $status = 'Up to date.'
        }
    }

    return @{
        SupportStatus = $status
        SupportPhase = $phase
        Channel = $channel
        EndOfSupportDate = $endOfSupportDate
        LatestPatchVersion = if ($null -ne $latestPatch) { $latestPatch.Text } else { $null }
    }
}

function Add-InstallationSupportStatus {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Installations,

        [switch] $SkipSupportCheck
    )

    foreach ($installation in $Installations) {
        $installation | Add-Member -NotePropertyMembers @{
            SupportStatus = if ($SkipSupportCheck) { 'Not checked' } else { 'Unknown' }
            SupportPhase = 'unknown'
            Channel = $null
            EndOfSupportDate = $null
            LatestPatchVersion = $null
        } -Force
    }
    if ($SkipSupportCheck -or $Installations.Count -eq 0) {
        return
    }

    $originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            $originalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        try {
            $releaseIndex = @(Get-ReleaseIndex)
        }
        catch {
            Write-Warning "Could not check .NET support status: $($_.Exception.Message) Local inventory is still available; support status is Unknown."
            return
        }

        $metadataCache = @{}
        $statusCache = @{}
        foreach ($installation in $Installations) {
            $key = "$($installation.ProductType)|$($installation.Version)"
            if (-not $statusCache.ContainsKey($key)) {
                try {
                    $statusCache[$key] = Get-InstallationSupportInfo -Installation $installation `
                        -ReleaseIndex $releaseIndex -MetadataCache $metadataCache
                }
                catch {
                    $statusCache[$key] = $null
                    Write-Warning "Could not check support status for $($installation.ProductType) $($installation.Version): $($_.Exception.Message) Support status is Unknown."
                }
            }
            if ($null -ne $statusCache[$key]) {
                $installation | Add-Member -NotePropertyMembers $statusCache[$key] -Force
            }
        }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
    }
}
