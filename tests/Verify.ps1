[CmdletBinding()]
param(
    [switch] $SkipOnlineChecks,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ModuleRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolvedModuleRoot = if ($PSBoundParameters.ContainsKey('ModuleRoot')) {
    (Resolve-Path -LiteralPath $ModuleRoot).Path
}
else {
    $repositoryRoot
}
$manifestPath = Join-Path $resolvedModuleRoot 'DotNetSteward.psd1'

Write-Host 'Checking PowerShell syntax...'
$powerShellFiles = @(
    Get-ChildItem -LiteralPath $resolvedModuleRoot -Recurse -File |
        Where-Object Extension -in @('.ps1', '.psd1', '.psm1')
)
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref] $tokens,
        [ref] $parseErrors
    )
    if (@($parseErrors).Count -gt 0) {
        $messages = @($parseErrors | ForEach-Object {
            '{0}:{1}: {2}' -f $file.FullName, $_.Extent.StartLineNumber, $_.Message
        })
        throw ($messages -join [Environment]::NewLine)
    }
}

if (-not $PSBoundParameters.ContainsKey('ModuleRoot')) {
    Write-Host 'Checking release automation...'
    & (Join-Path $PSScriptRoot 'Verify-ReleaseAutomation.ps1')
}

Write-Host 'Checking the module manifest and exports...'
$manifest = Test-ModuleManifest -Path $manifestPath
Assert-Condition ($manifest.RootModule -eq 'DotNetSteward.psm1') `
    'The manifest does not reference DotNetSteward.psm1.'

Remove-Module DotNetSteward -Force -ErrorAction SilentlyContinue
Import-Module $manifestPath -Force
$module = Get-Module DotNetSteward
Assert-Condition ($null -ne $module) 'DotNetSteward did not import.'

$expectedExports = @(
    'Find-DotNetRuntime'
    'Find-DotNetSdk'
    'Get-DotNetInstallation'
    'Install-DotNetRuntime'
    'Install-DotNetSdk'
    'Update-DotNetRuntime'
    'Update-DotNetSdk'
)
$actualExports = @($module.ExportedFunctions.Keys | Sort-Object)
$exportDifference = @(Compare-Object ($expectedExports | Sort-Object) $actualExports)
Assert-Condition ($exportDifference.Count -eq 0) `
    "Unexpected exported functions: $($actualExports -join ', ')."

Write-Host 'Checking versioning and installer identity behavior...'
$privateChecks = & $module {
    $preview2 = New-SdkVersionInfo -Text '11.0.0-preview.2.10'
    $preview10 = New-SdkVersionInfo -Text '11.0.0-preview.10.2'
    $releaseCandidate = New-SdkVersionInfo -Text '11.0.0-rc.1'
    $stable = New-SdkVersionInfo -Text '11.0.0'
    $identity = Get-DotNetBundleIdentity `
        -DisplayName 'Microsoft Windows Desktop Runtime - 10.0.12 (arm64)' `
        -BundleCachePath 'C:\cache\windowsdesktop-runtime-10.0.12-win-arm64.exe' `
        -UninstallString 'C:\cache\windowsdesktop-runtime-10.0.12-win-arm64.exe /uninstall'

    [pscustomobject] @{
        NumericPrereleaseOrder =
            (Compare-SdkVersion -Left $preview2 -Right $preview10) -lt 0
        ReleaseCandidateBeforeStable =
            (Compare-SdkVersion -Left $releaseCandidate -Right $stable) -lt 0
        HumanizedPreview =
            (Get-DotNetVersionFromDisplayName `
                'Microsoft .NET Runtime - 11.0.0 RC 1 (arm64)') -eq '11.0.0-rc.1'
        ProductType = $identity.ProductType
        Version = $identity.Version
        Architecture = $identity.Architecture
        ModernSignerAllowed = $script:ExpectedSignerSubjects.ContainsKey(
            'CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        )
        LegacySignerAllowed = $script:ExpectedSignerSubjects.ContainsKey(
            'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        )
    }
}
Assert-Condition $privateChecks.NumericPrereleaseOrder `
    'Numeric prerelease identifiers were not ordered numerically.'
Assert-Condition $privateChecks.ReleaseCandidateBeforeStable `
    'A release candidate did not sort before its stable release.'
Assert-Condition $privateChecks.HumanizedPreview `
    'A humanized prerelease display version was not normalized.'
Assert-Condition (
    $privateChecks.ProductType -eq 'WindowsDesktopRuntime' -and
    $privateChecks.Version -eq '10.0.12' -and
    $privateChecks.Architecture -eq 'arm64'
) 'The Arm64 Windows Desktop Runtime bundle identity was not parsed correctly.'
Assert-Condition (
    $privateChecks.ModernSignerAllowed -and $privateChecks.LegacySignerAllowed
) 'The expected modern and legacy Microsoft installer signers are not configured.'
$null = & $module {
    @(Get-DotNetPayloadInventory -Bundles @())
}

Write-Host 'Checking release discovery and fresh-install planning...'
$releaseDiscoveryChecks = & $module {
    function Get-ReleaseIndex {
        @(
            [pscustomobject] @{
                'channel-version' = '11.0'
                'support-phase' = 'preview'
                'release-type' = 'sts'
            }
            [pscustomobject] @{
                'channel-version' = '8.0'
                'support-phase' = 'active'
                'release-type' = 'lts'
            }
        )
    }

    function New-SyntheticInstaller {
        param(
            [string] $Version,
            [string] $Rid,
            [string] $ProductType = 'Sdk'
        )

        [pscustomobject] @{
            ProductType = $ProductType
            ProductLabel = Get-DotNetProductLabel -ProductType $ProductType
            Version = $Version
            VersionInfo = New-SdkVersionInfo -Text $Version
            Rid = $Rid
            Url = "https://example.invalid/$ProductType/$Version/$Rid.exe"
            Hash = ('A' * 128) -join ''
            HashAlgorithm = 'SHA512'
        }
    }

    function Get-ChannelSdkInstallers {
        param(
            [object] $ChannelEntry,
            [string] $Rid,
            [hashtable] $MetadataCache
        )

        if ($ChannelEntry.'channel-version' -eq '11.0') {
            return @(
                New-SyntheticInstaller -Version '11.0.100-preview.7' -Rid $Rid
                New-SyntheticInstaller -Version '11.0.100-rc.1' -Rid $Rid
            )
        }

        return @(
            New-SyntheticInstaller -Version '8.0.100' -Rid $Rid
            New-SyntheticInstaller -Version '8.0.199' -Rid $Rid
            New-SyntheticInstaller -Version '8.0.200-preview.1' -Rid $Rid
            New-SyntheticInstaller -Version '8.0.200' -Rid $Rid
        )
    }

    function Get-ChannelRuntimeInstallers {
        param(
            [object] $ChannelEntry,
            [string] $Rid,
            [string] $ProductType,
            [hashtable] $MetadataCache
        )

        if ($ChannelEntry.'channel-version' -eq '11.0') {
            return @(
                New-SyntheticInstaller -Version '11.0.0-preview.7' `
                    -Rid $Rid -ProductType $ProductType
                New-SyntheticInstaller -Version '11.0.0-rc.1' `
                    -Rid $Rid -ProductType $ProductType
            )
        }

        return @(
            New-SyntheticInstaller -Version '8.0.1' -Rid $Rid `
                -ProductType $ProductType
            New-SyntheticInstaller -Version '8.0.2' -Rid $Rid `
                -ProductType $ProductType
        )
    }

    $defaultSdks = @(Find-DotNetSdk -Architecture x64)
    $previewSdk = @(
        Find-DotNetSdk -Channel 11.0 -Architecture x64 -IncludePreview
    )
    $stablePreviewChannel = @(
        Find-DotNetSdk -Channel 11.0 -Architecture x64
    )
    $bandSdk = @(
        Find-DotNetSdk -VersionBand 8.0.1xx -Architecture x64
    )
    $allStableSdks = @(
        Find-DotNetSdk -Channel 8.0 -Architecture x64 -AllVersions
    )
    $exactPreviewSdks = @(
        Find-DotNetSdk -Version 11.0.100-preview.7 -Architecture x64
    )
    $multipleExactSdks = @(
        Find-DotNetSdk -Version 8.0.100, 8.0.199 -Architecture x64
    )
    $runtimeProducts = @(
        Find-DotNetRuntime -Channel 8.0 -Architecture x64
    )

    $sdkInstallPlanned = $true
    $runtimeInstallPlanned = $true
    try {
        Install-DotNetSdk -Version 8.0.100 -Architecture x64 -WhatIf
    }
    catch {
        $sdkInstallPlanned = $false
    }
    try {
        Install-DotNetRuntime -ProductType WindowsDesktopRuntime `
            -Channel 8.0 -Architecture x64 -WhatIf
    }
    catch {
        $runtimeInstallPlanned = $false
    }

    [pscustomobject] @{
        DefaultSdkVersions = @($defaultSdks.Version)
        PreviewSdkVersion = $previewSdk.Version
        StablePreviewChannelCount = $stablePreviewChannel.Count
        BandSdkVersion = $bandSdk.Version
        AllStableSdkVersions = @($allStableSdks.Version)
        ExactPreviewSdkVersion = $exactPreviewSdks.Version
        MultipleExactSdkCount = $multipleExactSdks.Count
        RuntimeProductTypes = @($runtimeProducts.ProductType)
        AvailableReleaseTypeName = $defaultSdks[0].PSTypeNames[0]
        SdkInstallPlanned = $sdkInstallPlanned
        RuntimeInstallPlanned = $runtimeInstallPlanned
    }
}
Assert-Condition (
    @($releaseDiscoveryChecks.DefaultSdkVersions).Count -eq 1 -and
    $releaseDiscoveryChecks.DefaultSdkVersions[0] -eq '8.0.200'
) 'Default SDK discovery did not return the latest stable SDK per channel.'
Assert-Condition (
    $releaseDiscoveryChecks.PreviewSdkVersion -eq '11.0.100-rc.1' -and
    $releaseDiscoveryChecks.StablePreviewChannelCount -eq 0
) 'SDK prerelease filtering did not behave as expected.'
Assert-Condition ($releaseDiscoveryChecks.BandSdkVersion -eq '8.0.199') `
    'SDK feature-band discovery did not select the latest matching release.'
Assert-Condition (
    @($releaseDiscoveryChecks.AllStableSdkVersions).Count -eq 3 -and
    $releaseDiscoveryChecks.AllStableSdkVersions -notcontains '8.0.200-preview.1'
) 'AllVersions did not return every stable SDK release.'
Assert-Condition (
    $releaseDiscoveryChecks.ExactPreviewSdkVersion -eq
        '11.0.100-preview.7'
) 'Exact prerelease SDK discovery incorrectly required IncludePreview.'
Assert-Condition ($releaseDiscoveryChecks.MultipleExactSdkCount -eq 2) `
    'Exact SDK discovery collapsed multiple versions in the same channel.'
Assert-Condition (
    @($releaseDiscoveryChecks.RuntimeProductTypes).Count -eq 3 -and
    $releaseDiscoveryChecks.RuntimeProductTypes -contains 'Runtime' -and
    $releaseDiscoveryChecks.RuntimeProductTypes -contains
        'AspNetCoreRuntime' -and
    $releaseDiscoveryChecks.RuntimeProductTypes -contains
        'WindowsDesktopRuntime'
) 'Runtime discovery did not return every runtime product by default.'
Assert-Condition (
    $releaseDiscoveryChecks.AvailableReleaseTypeName -eq
        'DotNetSteward.AvailableRelease'
) 'Available releases do not have the expected PowerShell type name.'
Assert-Condition (
    $releaseDiscoveryChecks.SdkInstallPlanned -and
    $releaseDiscoveryChecks.RuntimeInstallPlanned
) 'Fresh-install target planning failed under WhatIf.'

Write-Host 'Checking the installed-product inventory...'
$installations = @(Get-DotNetInstallation)
foreach ($installation in $installations) {
    foreach ($propertyName in @(
        'ProductType',
        'Version',
        'Architecture',
        'ManagementSource',
        'ManagedByVisualStudio',
        'IsUpdateable',
        'IsUninstallable'
    )) {
        Assert-Condition ($null -ne $installation.PSObject.Properties[$propertyName]) `
            "An inventory record is missing '$propertyName'."
    }

    if ($installation.InstallerKind -eq 'Payload') {
        Assert-Condition (-not $installation.IsUpdateable) `
            'An MSI payload was incorrectly marked updateable.'
        Assert-Condition (-not $installation.IsUninstallable) `
            'An MSI payload was incorrectly marked uninstallable.'
    }
    if ($installation.ManagedByVisualStudio) {
        Assert-Condition (-not $installation.IsUpdateable) `
            'A Visual Studio-managed installation was incorrectly marked updateable.'
        Assert-Condition (-not $installation.IsUninstallable) `
            'A Visual Studio-managed installation was incorrectly marked uninstallable.'
    }
}
Write-Host "  Found $($installations.Count) installer-managed .NET installation(s)."

if (-not $SkipOnlineChecks) {
    Write-Host 'Checking official runtime release metadata...'
    $originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            $originalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $metadataCheck = & $module {
            $releaseIndex = @(Get-ReleaseIndex)
            $selectedEntry = $null
            $selectedVersion = $null
            foreach ($entry in $releaseIndex) {
                $latestRuntimeProperty = $entry.PSObject.Properties['latest-runtime']
                if ($null -eq $latestRuntimeProperty) {
                    continue
                }

                try {
                    $versionInfo = New-SdkVersionInfo `
                        -Text ([string] $latestRuntimeProperty.Value)
                }
                catch {
                    continue
                }
                if (-not $versionInfo.IsStable) {
                    continue
                }
                if ($null -eq $selectedVersion -or
                    (Compare-SdkVersion -Left $versionInfo -Right $selectedVersion) -gt 0) {
                    $selectedEntry = $entry
                    $selectedVersion = $versionInfo
                }
            }

            if ($null -eq $selectedEntry) {
                throw 'No stable runtime channel was found in the releases index.'
            }

            $installers = @(
                Get-ChannelRuntimeInstallers -ChannelEntry $selectedEntry `
                    -Rid 'win-x64' -ProductType Runtime
            )
            $latestInstaller = Get-LatestVersionedItem -Items $installers
            if ($null -eq $latestInstaller) {
                throw 'No win-x64 .NET Runtime installer was found.'
            }

            [pscustomobject] @{
                Version = $latestInstaller.Version
                Url = $latestInstaller.Url
                Hash = $latestInstaller.Hash
            }
        }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
    }

    Assert-Condition ($metadataCheck.Url -match '^https://') `
        'Runtime metadata returned a non-HTTPS installer URL.'
    Assert-Condition ($metadataCheck.Hash -match '^[0-9A-F]{128}$') `
        'Runtime metadata returned an invalid SHA-512 hash.'
    Write-Host "  Resolved .NET Runtime $($metadataCheck.Version) for win-x64."
}

Write-Host 'Checking Visual Studio ownership behavior...'
$ownershipCheck = & $module {
    function Get-DotNetBundleInventory {
        [pscustomobject] @{
            PSTypeName = 'DotNetSteward.Installation'
            ProductType = 'Sdk'
            Version = '8.0.425'
            VersionInfo = New-SdkVersionInfo -Text '8.0.425'
            Architecture = 'x64'
            Rid = 'win-x64'
            InstallerKind = 'Bundle'
            ManagementSource = 'Standalone'
            ManagedByVisualStudio = $false
            Owners = @('Standalone SDK')
            IsUpdateable = $true
            IsUninstallable = $true
            DisplayName = 'Standalone SDK'
            BundleId = '{11111111-1111-1111-1111-111111111111}'
        }
    }

    function Get-DotNetPayloadInventory {
        param([object[]] $Bundles)

        @(
            [pscustomobject] @{
                PSTypeName = 'DotNetSteward.Installation'
                ProductType = 'Sdk'
                Version = '8.0.425'
                VersionInfo = New-SdkVersionInfo -Text '8.0.425'
                Architecture = 'x64'
                Rid = 'win-x64'
                InstallerKind = 'Payload'
                ManagementSource = 'VisualStudio'
                ManagedByVisualStudio = $true
                Owners = @('Visual Studio')
                IsUpdateable = $false
                IsUninstallable = $false
            }
            [pscustomobject] @{
                PSTypeName = 'DotNetSteward.Installation'
                ProductType = 'Runtime'
                Version = '8.0.31'
                VersionInfo = New-SdkVersionInfo -Text '8.0.31'
                Architecture = 'x64'
                Rid = 'win-x64'
                InstallerKind = 'Payload'
                ManagementSource = 'VisualStudio'
                ManagedByVisualStudio = $true
                Owners = @('Visual Studio')
                IsUpdateable = $false
                IsUninstallable = $false
            }
        )
    }

    $items = @(Get-DotNetInstallationInventory)
    $sdk = $items | Where-Object ProductType -eq 'Sdk'
    $runtime = $items | Where-Object ProductType -eq 'Runtime'
    [pscustomobject] @{
        Count = $items.Count
        SdkManagementSource = $sdk.ManagementSource
        SdkManagedByVisualStudio = $sdk.ManagedByVisualStudio
        SdkUpdateable = $sdk.IsUpdateable
        SdkUninstallable = $sdk.IsUninstallable
        RuntimeManagementSource = $runtime.ManagementSource
        RuntimeUpdateable = $runtime.IsUpdateable
    }
}
Assert-Condition ($ownershipCheck.Count -eq 2) `
    'Synthetic ownership records were not merged correctly.'
Assert-Condition (
    $ownershipCheck.SdkManagementSource -eq 'StandaloneAndVisualStudio' -and
    $ownershipCheck.SdkManagedByVisualStudio -and
    -not $ownershipCheck.SdkUpdateable -and
    -not $ownershipCheck.SdkUninstallable
) 'A shared SDK installation was not made read-only.'
Assert-Condition (
    $ownershipCheck.RuntimeManagementSource -eq 'VisualStudio' -and
    -not $ownershipCheck.RuntimeUpdateable
) 'A Visual Studio runtime payload was not kept read-only.'

Write-Host 'DotNetSteward verification passed.'
