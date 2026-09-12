function Get-DotNetProductType {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $DisplayName
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        return $null
    }

    if ($DisplayName.IndexOf('.NET Core SDK', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $DisplayName.IndexOf('Microsoft .NET SDK', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return 'Sdk'
    }

    if ($DisplayName.IndexOf('ASP.NET', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        ($DisplayName.IndexOf('Runtime', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $DisplayName.IndexOf('Shared Framework', [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
        return 'AspNetCoreRuntime'
    }

    if ($DisplayName.IndexOf('Windows Desktop Runtime', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $DisplayName.IndexOf(
            'Dotnet Shared Framework for Windows Desktop',
            [StringComparison]::OrdinalIgnoreCase
        ) -ge 0) {
        return 'WindowsDesktopRuntime'
    }

    if ($DisplayName.IndexOf('.NET Core Runtime', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $DisplayName.IndexOf('Microsoft .NET Runtime', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return 'Runtime'
    }

    return $null
}

function Get-DotNetVersionFromDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $DisplayName
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        return $null
    }

    if ($DisplayName -match '(?i)(?<core>\d+\.\d+\.\d+)\s+(?<label>preview|alpha|rc)\s*(?<number>\d+(?:\.\d+)*)') {
        return '{0}-{1}.{2}' -f
            $Matches.core,
            $Matches.label.ToLowerInvariant(),
            $Matches.number
    }

    if ($DisplayName -match '(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)') {
        return $Matches.version
    }

    return $null
}

function Get-DotNetBundleIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DisplayName,

        [AllowEmptyString()]
        [string] $BundleCachePath,

        [AllowEmptyString()]
        [string] $UninstallString
    )

    $productType = Get-DotNetProductType -DisplayName $DisplayName
    if ($null -eq $productType) {
        return $null
    }

    $version = $null
    $architecture = $null
    $identityText = "$BundleCachePath`n$UninstallString"
    if ($identityText -match '(?i)(?:dotnet-sdk|dotnet-runtime|aspnetcore-runtime|windowsdesktop-runtime)-(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)-win-(?<architecture>x64|x86|arm64)\.exe') {
        $version = $Matches.version
        $architecture = $Matches.architecture.ToLowerInvariant()
    }
    elseif ($identityText -match '(?i)dotnet-(?:dev-)?win-(?<architecture>x64|x86)\.(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\.exe') {
        $version = $Matches.version
        $architecture = $Matches.architecture.ToLowerInvariant()
    }

    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = Get-DotNetVersionFromDisplayName -DisplayName $DisplayName
    }
    if ([string]::IsNullOrWhiteSpace($architecture) -and
        $DisplayName -match '(?i)\((?<architecture>x64|x86|arm64)\)') {
        $architecture = $Matches.architecture.ToLowerInvariant()
    }

    if ([string]::IsNullOrWhiteSpace($version) -or
        [string]::IsNullOrWhiteSpace($architecture)) {
        return $null
    }

    [pscustomobject] @{
        ProductType = $productType
        Version = $version
        Architecture = $architecture
        Rid = "win-$architecture"
    }
}

function Get-DotNetBundleInventory {
    $registryHive = [Microsoft.Win32.RegistryHive]::LocalMachine
    # Official .NET Burn bundles register in the 32-bit Add/Remove Programs view.
    $registryView = [Microsoft.Win32.RegistryView]::Registry32
    $uninstallPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $bundles = New-Object System.Collections.Generic.List[object]
    $baseKey = $null
    $uninstallKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($registryHive, $registryView)
        $uninstallKey = $baseKey.OpenSubKey($uninstallPath)
        if ($null -eq $uninstallKey) {
            return @()
        }

        foreach ($subkeyName in $uninstallKey.GetSubKeyNames()) {
            $bundleKey = $uninstallKey.OpenSubKey($subkeyName)
            if ($null -eq $bundleKey) {
                continue
            }

            try {
                $displayName = [string] $bundleKey.GetValue('DisplayName')
                $displayVersion = [string] $bundleKey.GetValue('DisplayVersion')
                $bundleVersion = [string] $bundleKey.GetValue('BundleVersion')
                $publisher = [string] $bundleKey.GetValue('Publisher')
                $uninstallString = [string] $bundleKey.GetValue('UninstallString')
                $quietUninstallString = [string] $bundleKey.GetValue('QuietUninstallString')
                $bundleCachePath = [string] $bundleKey.GetValue('BundleCachePath')

                $productType = Get-DotNetProductType -DisplayName $displayName
                $isVisualStudioOwned =
                    $displayName.IndexOf('Visual Studio', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $displayName.IndexOf('VS 2015', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $displayName.IndexOf('Local Feed', [StringComparison]::OrdinalIgnoreCase) -ge 0
                $isExeBundle =
                    $uninstallString.IndexOf('.exe', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                    $uninstallString.IndexOf('msiexec', [StringComparison]::OrdinalIgnoreCase) -lt 0

                if ($null -eq $productType -or -not $isExeBundle -or
                    $publisher -cne 'Microsoft Corporation' -or
                    [string]::IsNullOrWhiteSpace($displayVersion) -or
                    [string]::IsNullOrWhiteSpace($bundleVersion)) {
                    continue
                }

                $identity = Get-DotNetBundleIdentity -DisplayName $displayName `
                    -BundleCachePath $bundleCachePath -UninstallString $uninstallString
                if ($null -eq $identity) {
                    Write-Warning "Ignoring .NET bundle '$displayName' because its version or architecture could not be determined."
                    continue
                }

                try {
                    $versionInfo = New-SdkVersionInfo -Text $identity.Version
                }
                catch {
                    Write-Warning "Ignoring .NET bundle '$displayName' because version '$($identity.Version)' is invalid."
                    continue
                }

                $bundleProviderKey = [string] $bundleKey.GetValue('BundleProviderKey')
                if ([string]::IsNullOrWhiteSpace($bundleProviderKey)) {
                    $bundleProviderKey = $subkeyName
                }

                $bundles.Add([pscustomobject] @{
                    PSTypeName = 'DotNetSteward.Installation'
                    ProductType = $identity.ProductType
                    Version = $versionInfo.Text
                    VersionInfo = $versionInfo
                    Architecture = $identity.Architecture
                    Rid = $identity.Rid
                    InstallerKind = 'Bundle'
                    ManagementSource = if ($isVisualStudioOwned) { 'VisualStudio' } else { 'Standalone' }
                    ManagedByVisualStudio = $isVisualStudioOwned
                    Owners = @($displayName)
                    IsUpdateable = -not $isVisualStudioOwned
                    IsUninstallable = -not $isVisualStudioOwned
                    DisplayName = $displayName
                    DisplayVersion = $displayVersion
                    BundleVersion = $bundleVersion
                    BundleId = $bundleProviderKey
                    BundleUpgradeCode = @($bundleKey.GetValue('BundleUpgradeCode'))
                    BundleCachePath = $bundleCachePath
                    UninstallString = $uninstallString
                    QuietUninstallString = $quietUninstallString
                    RegistryView = [string] $registryView
                    RegistrySubkey = "$uninstallPath\$subkeyName"
                })
            }
            finally {
                $bundleKey.Dispose()
            }
        }
    }
    finally {
        if ($null -ne $uninstallKey) {
            $uninstallKey.Dispose()
        }
        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }

    return $bundles.ToArray()
}

function Get-DotNetSdkBundleInventory {
    return @(
        Get-DotNetInstallationInventory |
            Where-Object {
                $_.ProductType -eq 'Sdk' -and
                    $_.InstallerKind -eq 'Bundle' -and
                    $_.IsUpdateable
            }
    )
}

function Get-DotNetDependencyMap {
    $dependencyPath = 'SOFTWARE\Classes\Installer\Dependencies'
    $byProductCode = @{}

    foreach ($registryView in @(
        [Microsoft.Win32.RegistryView]::Registry32,
        [Microsoft.Win32.RegistryView]::Registry64
    )) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $registryView
        )
        $dependenciesKey = $baseKey.OpenSubKey($dependencyPath)
        try {
            if ($null -eq $dependenciesKey) {
                continue
            }

            foreach ($providerName in $dependenciesKey.GetSubKeyNames()) {
                $providerKey = $dependenciesKey.OpenSubKey($providerName)
                if ($null -eq $providerKey) {
                    continue
                }
                try {
                    $productCode = [string] $providerKey.GetValue($null)
                    if ($productCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
                        continue
                    }

                    $dependentsKey = $providerKey.OpenSubKey('Dependents')
                    try {
                        $dependents = if ($null -ne $dependentsKey) {
                            @($dependentsKey.GetSubKeyNames())
                        }
                        else {
                            @()
                        }
                    }
                    finally {
                        if ($null -ne $dependentsKey) {
                            $dependentsKey.Dispose()
                        }
                    }

                    $mapKey = $productCode.ToUpperInvariant()
                    if (-not $byProductCode.ContainsKey($mapKey)) {
                        $byProductCode[$mapKey] = [pscustomobject] @{
                            ProviderKeys = New-Object System.Collections.Generic.List[string]
                            Dependents = New-Object System.Collections.Generic.List[string]
                        }
                    }

                    if (-not $byProductCode[$mapKey].ProviderKeys.Contains($providerName)) {
                        $byProductCode[$mapKey].ProviderKeys.Add($providerName)
                    }
                    foreach ($dependent in $dependents) {
                        if (-not $byProductCode[$mapKey].Dependents.Contains($dependent)) {
                            $byProductCode[$mapKey].Dependents.Add($dependent)
                        }
                    }
                }
                finally {
                    $providerKey.Dispose()
                }
            }
        }
        finally {
            if ($null -ne $dependenciesKey) {
                $dependenciesKey.Dispose()
            }
            $baseKey.Dispose()
        }
    }

    return $byProductCode
}

function Get-DotNetInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string] $Architecture
    )

    $setupPath = "SOFTWARE\dotnet\Setup\InstalledVersions\$Architecture"
    foreach ($registryView in @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $registryView
        )
        $setupKey = $baseKey.OpenSubKey($setupPath)
        try {
            if ($null -ne $setupKey) {
                $installLocation = [string] $setupKey.GetValue('InstallLocation')
                if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                    return $installLocation
                }
            }
        }
        finally {
            if ($null -ne $setupKey) {
                $setupKey.Dispose()
            }
            $baseKey.Dispose()
        }
    }

    return $null
}

function Resolve-DotNetPayloadVersion {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Sdk', 'Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string] $ProductType,

        [Parameter(Mandatory = $true)]
        [object] $VersionInfo,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string] $Architecture,

        [AllowEmptyCollection()]
        [object[]] $OwnerBundles = @()
    )

    if ($VersionInfo.IsStable) {
        return $VersionInfo
    }

    $installRoot = Get-DotNetInstallRoot -Architecture $Architecture
    if ([string]::IsNullOrWhiteSpace($installRoot)) {
        return $VersionInfo
    }

    if ($ProductType -eq 'Sdk') {
        $frameworkPath = Join-Path $installRoot 'sdk'
    }
    else {
        $frameworkName = switch ($ProductType) {
            'Runtime' { 'Microsoft.NETCore.App' }
            'AspNetCoreRuntime' { 'Microsoft.AspNetCore.App' }
            'WindowsDesktopRuntime' { 'Microsoft.WindowsDesktop.App' }
        }
        $frameworkPath = Join-Path (Join-Path $installRoot 'shared') $frameworkName
    }

    if (-not (Test-Path -LiteralPath $frameworkPath -PathType Container)) {
        return $VersionInfo
    }

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($directory in Get-ChildItem -LiteralPath $frameworkPath -Directory -ErrorAction Stop) {
        if ($directory.Name -ne $VersionInfo.Text -and
            -not $directory.Name.StartsWith("$($VersionInfo.Text).", [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        try {
            $matches.Add([pscustomobject] @{
                VersionInfo = New-SdkVersionInfo -Text $directory.Name
            })
        }
        catch {
            continue
        }
    }

    if ($matches.Count -eq 0) {
        return $VersionInfo
    }

    foreach ($ownerBundle in $OwnerBundles) {
        if ($ownerBundle.ProductType -eq $ProductType -and
            ($ownerBundle.VersionInfo.Text -eq $VersionInfo.Text -or
            $ownerBundle.VersionInfo.Text.StartsWith(
                "$($VersionInfo.Text).",
                [StringComparison]::OrdinalIgnoreCase
            ))) {
            return $ownerBundle.VersionInfo
        }

        if ($ownerBundle.VersionInfo.Major -eq $VersionInfo.Major -and
            $ownerBundle.VersionInfo.Minor -eq $VersionInfo.Minor -and
            -not [string]::IsNullOrWhiteSpace($ownerBundle.VersionInfo.Prerelease)) {
            $ownerMatch = @($matches | Where-Object {
                $_.VersionInfo.Prerelease -ceq $ownerBundle.VersionInfo.Prerelease
            })
            if ($ownerMatch.Count -eq 1) {
                return $ownerMatch[0].VersionInfo
            }
        }
    }

    if ($matches.Count -eq 1) {
        return $matches[0].VersionInfo
    }

    return $VersionInfo
}

function Get-DotNetPayloadInventory {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Bundles
    )

    $uninstallPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $visualStudioDependent = 'VS.{AEF703B8-D2CC-4343-915C-F54A30B90937}'
    $dependencyMap = Get-DotNetDependencyMap
    $bundleById = @{}
    foreach ($bundle in $Bundles) {
        $bundleById[$bundle.BundleId.ToUpperInvariant()] = $bundle
    }
    $payloads = New-Object System.Collections.Generic.List[object]

    foreach ($registryView in @(
        [Microsoft.Win32.RegistryView]::Registry32,
        [Microsoft.Win32.RegistryView]::Registry64
    )) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $registryView
        )
        $uninstallKey = $baseKey.OpenSubKey($uninstallPath)
        try {
            if ($null -eq $uninstallKey) {
                continue
            }

            foreach ($subkeyName in $uninstallKey.GetSubKeyNames()) {
                $productKey = $uninstallKey.OpenSubKey($subkeyName)
                if ($null -eq $productKey) {
                    continue
                }
                try {
                    $displayName = [string] $productKey.GetValue('DisplayName')
                    $publisher = [string] $productKey.GetValue('Publisher')
                    $uninstallString = [string] $productKey.GetValue('UninstallString')
                    $productType = Get-DotNetProductType -DisplayName $displayName
                    if ($null -eq $productType -or $publisher -cne 'Microsoft Corporation' -or
                        $uninstallString.IndexOf('msiexec', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                        continue
                    }

                    $version = Get-DotNetVersionFromDisplayName -DisplayName $displayName
                    if ([string]::IsNullOrWhiteSpace($version) -or
                        $displayName -notmatch '(?i)\((?<architecture>x64|x86|arm64)\)') {
                        continue
                    }
                    $architecture = $Matches.architecture.ToLowerInvariant()

                    $productCode = $subkeyName.ToUpperInvariant()
                    $providerKeys = @()
                    $dependentIds = @()
                    if ($dependencyMap.ContainsKey($productCode)) {
                        $providerKeys = $dependencyMap[$productCode].ProviderKeys.ToArray()
                        $dependentIds = $dependencyMap[$productCode].Dependents.ToArray()
                    }

                    $managedByVisualStudio = $false
                    $owners = New-Object System.Collections.Generic.List[string]
                    $ownerBundles = New-Object System.Collections.Generic.List[object]
                    foreach ($dependentId in $dependentIds) {
                        if ($dependentId -eq $visualStudioDependent) {
                            $managedByVisualStudio = $true
                            if (-not $owners.Contains('Visual Studio')) {
                                $owners.Add('Visual Studio')
                            }
                            continue
                        }

                        $dependentKey = $dependentId.ToUpperInvariant()
                        if ($bundleById.ContainsKey($dependentKey)) {
                            $ownerBundle = $bundleById[$dependentKey]
                            $ownerName = $ownerBundle.DisplayName
                            if (-not $ownerBundles.Contains($ownerBundle)) {
                                $ownerBundles.Add($ownerBundle)
                            }
                        }
                        else {
                            $ownerName = $dependentId
                        }
                        if (-not $owners.Contains($ownerName)) {
                            $owners.Add($ownerName)
                        }
                    }

                    try {
                        $versionInfo = New-SdkVersionInfo -Text $version
                    }
                    catch {
                        Write-Warning "Ignoring .NET payload '$displayName' because version '$version' is invalid."
                        continue
                    }

                    try {
                        $versionInfo = Resolve-DotNetPayloadVersion -ProductType $productType `
                            -VersionInfo $versionInfo -Architecture $architecture `
                            -OwnerBundles $ownerBundles.ToArray()
                    }
                    catch {
                        Write-Warning "Could not refine the prerelease version for .NET payload '$displayName'; using '$version'. $($_.Exception.Message)"
                    }

                    $managementSource = if ($managedByVisualStudio) {
                        'VisualStudio'
                    }
                    elseif ($owners.Count -gt 0) {
                        'SharedInstaller'
                    }
                    else {
                        'WindowsInstaller'
                    }

                    $payloads.Add([pscustomobject] @{
                        PSTypeName = 'DotNetSteward.Installation'
                        ProductType = $productType
                        Version = $versionInfo.Text
                        VersionInfo = $versionInfo
                        Architecture = $architecture
                        Rid = "win-$architecture"
                        InstallerKind = 'Payload'
                        ManagementSource = $managementSource
                        ManagedByVisualStudio = $managedByVisualStudio
                        Owners = $owners.ToArray()
                        IsUpdateable = $false
                        IsUninstallable = $false
                        DisplayName = $displayName
                        DisplayVersion = [string] $productKey.GetValue('DisplayVersion')
                        ProductCode = $subkeyName
                        DependencyProviderKeys = $providerKeys
                        RegistryView = [string] $registryView
                        RegistrySubkey = "$uninstallPath\$subkeyName"
                    })
                }
                finally {
                    $productKey.Dispose()
                }
            }
        }
        finally {
            if ($null -ne $uninstallKey) {
                $uninstallKey.Dispose()
            }
            $baseKey.Dispose()
        }
    }

    return $payloads.ToArray()
}

function Get-DotNetInstallationInventory {
    $bundles = @(Get-DotNetBundleInventory)
    $payloads = @(Get-DotNetPayloadInventory -Bundles $bundles)
    $payloadsByIdentity = @{}

    foreach ($payload in $payloads) {
        $identity = "$($payload.ProductType)|$($payload.Version)|$($payload.Architecture)"
        if (-not $payloadsByIdentity.ContainsKey($identity)) {
            $payloadsByIdentity[$identity] = New-Object System.Collections.Generic.List[object]
        }
        $payloadsByIdentity[$identity].Add($payload)
    }

    $installations = New-Object System.Collections.Generic.List[object]
    foreach ($bundle in $bundles) {
        $identity = "$($bundle.ProductType)|$($bundle.Version)|$($bundle.Architecture)"
        if ($payloadsByIdentity.ContainsKey($identity)) {
            foreach ($payload in $payloadsByIdentity[$identity]) {
                if ($payload.ManagedByVisualStudio) {
                    $bundle.ManagedByVisualStudio = $true
                    $bundle.ManagementSource = 'StandaloneAndVisualStudio'
                    $bundle.IsUpdateable = $false
                    $bundle.IsUninstallable = $false
                }
                $bundle.Owners = @($bundle.Owners + $payload.Owners | Sort-Object -Unique)
            }
            $payloadsByIdentity.Remove($identity)
        }
        $installations.Add($bundle)
    }

    foreach ($remainingPayloads in $payloadsByIdentity.Values) {
        foreach ($payload in $remainingPayloads) {
            $installations.Add($payload)
        }
    }

    return $installations.ToArray()
}

function Sort-DotNetInstallations {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Installations
    )

    $sorted = New-Object System.Collections.Generic.List[object]
    foreach ($installation in $Installations) {
        $insertAt = $sorted.Count
        for ($index = 0; $index -lt $sorted.Count; $index++) {
            $comparison = [string]::CompareOrdinal(
                [string] $installation.ProductType,
                [string] $sorted[$index].ProductType
            )
            if ($comparison -eq 0) {
                $comparison = [string]::CompareOrdinal(
                    [string] $installation.Architecture,
                    [string] $sorted[$index].Architecture
                )
            }
            if ($comparison -eq 0) {
                $comparison = Compare-SdkVersion -Left $installation.VersionInfo `
                    -Right $sorted[$index].VersionInfo
            }
            if ($comparison -lt 0) {
                $insertAt = $index
                break
            }
        }
        $sorted.Insert($insertAt, $installation)
    }

    return $sorted.ToArray()
}
