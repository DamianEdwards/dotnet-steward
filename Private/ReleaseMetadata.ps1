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
