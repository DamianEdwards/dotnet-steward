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
    'Uninstall-DotNetRuntime'
    'Uninstall-DotNetSdk'
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

    $integerSdk = @(Find-DotNetSdk -Channel 11 -Architecture x64 -IncludePreview)
    $integerStableSdk = @(Find-DotNetSdk -Channel 11 -Architecture x64)
    $integerRuntime = @(Find-DotNetRuntime -Channel 11 -Architecture x64 -IncludePreview)
    $integerStableRuntime = @(Find-DotNetRuntime -Channel 11 -Architecture x64)
    $integerSdkArray = @(Find-DotNetSdk -Channel 8, 11 -Architecture x64 -IncludePreview)
    $mixedSdkArray = @(Find-DotNetSdk -Channel '8.0', 11 -Architecture x64 -IncludePreview)
    $mixedRuntimeArray = @(Find-DotNetRuntime -Channel 8, '11.0' `
        -Architecture x64 -IncludePreview)
    $duplicateSdkChannels = @(Find-DotNetSdk -Channel 8, '8.0' -Architecture x64)
    $normalizedChannels = @(ConvertTo-DotNetChannels -Channels @('2.1', 8, '11'))

    $script:ChannelPlans = @()
    function Invoke-DotNetInstallerPlan {
        param($Candidates, $ShowInstallerUi, $CompletionSubject, $Elevate)
        $script:ChannelPlans += ,@($Candidates)
    }
    Install-DotNetSdk -Channel 8, 11 -Architecture x64 -IncludePreview
    Install-DotNetRuntime -Channel '8.0', 11 -Architecture x64, x86 `
        -ProductType Runtime, WindowsDesktopRuntime -IncludePreview
    Install-DotNetRuntime -Channel 8, '8.0' -Architecture x64
    $integerInstallResolved = $script:ChannelPlans.Count -eq 3 -and
        $script:ChannelPlans[0].Count -eq 2 -and
        ($script:ChannelPlans[0].TargetVersion -join ',') -eq '11.0.100-rc.1,8.0.200' -and
        $script:ChannelPlans[1].Count -eq 8 -and
        $script:ChannelPlans[2].Count -eq 1

    $invalidChannelRefused = $true
    foreach ($command in @('Find-DotNetSdk', 'Find-DotNetRuntime',
        'Install-DotNetSdk', 'Install-DotNetRuntime')) {
        foreach ($selector in @('-1', '11.x', '11.0.1', '11-preview', ' ', '8,11')) {
            $refused = $false
            try {
                & $command -Channel $selector -Architecture x64
            }
            catch {
                $refused = $_.Exception.Message -like 'Invalid .NET channel*'
            }
            $invalidChannelRefused = $invalidChannelRefused -and $refused
        }
    }
    $unavailableChannelRefused = $false
    try {
        Install-DotNetSdk -Channel 99 -Architecture x64
    }
    catch {
        $unavailableChannelRefused = $_.Exception.Message -match "Channel '99.0'"
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
        IntegerChannelsResolved = $integerSdk.Count -eq 1 -and
            $integerSdk[0].Channel -eq '11.0' -and $integerSdk[0].Version -eq '11.0.100-rc.1' -and
            $integerRuntime.Count -eq 3 -and
            @($integerRuntime | Where-Object Channel -ne '11.0').Count -eq 0 -and
            @($integerRuntime | Where-Object Version -ne '11.0.0-rc.1').Count -eq 0
        IntegerPreviewGated = $integerStableSdk.Count -eq 0 -and $integerStableRuntime.Count -eq 0
        ChannelArraysResolved = ($integerSdkArray.Version -join ',') -eq '11.0.100-rc.1,8.0.200' -and
            ($mixedSdkArray.Version -join ',') -eq ($integerSdkArray.Version -join ',') -and
            $mixedRuntimeArray.Count -eq 6 -and
            $duplicateSdkChannels.Count -eq 1 -and
            ($normalizedChannels -join ',') -eq '2.1,8.0,11.0'
        IntegerInstallResolved = $integerInstallResolved
        InvalidChannelRefused = $invalidChannelRefused
        UnavailableChannelRefused = $unavailableChannelRefused
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
foreach ($property in @('IntegerChannelsResolved', 'IntegerPreviewGated', 'ChannelArraysResolved',
    'IntegerInstallResolved', 'InvalidChannelRefused', 'UnavailableChannelRefused')) {
    Assert-Condition $releaseDiscoveryChecks.$property "Channel shorthand check '$property' failed."
}

Write-Host 'Checking empty-result feedback across public commands...'
$emptyResultChecks = & $module {
    $script:InventoryPresent = $false
    $script:ReleasesPresent = $false
    $script:MetadataRequests = 0
    function Get-DotNetInstallationInventory {
        if ($script:InventoryPresent) {
            foreach ($product in @('Sdk', 'Runtime')) {
                [pscustomobject] @{
                    ProductType = $product; Version = '8.0.100'
                    VersionInfo = New-SdkVersionInfo -Text '8.0.100'
                    Architecture = 'x64'; Rid = 'win-x64'; InstallerKind = 'Bundle'
                    IsUpdateable = $true; IsUninstallable = $true
                    ManagementSource = 'Standalone'
                }
            }
        }
    }
    function Get-DotNetSdkBundleInventory {
        return Get-DotNetInstallationInventory | Where-Object ProductType -eq 'Sdk'
    }
    function Get-ReleaseIndex {
        $script:MetadataRequests++
        return [pscustomobject] @{
            'channel-version' = '8.0'; 'support-phase' = 'active'; 'release-type' = 'lts'
        }
    }
    function Get-ChannelSdkInstallers {
        param($ChannelEntry, $Rid, $MetadataCache)
        if ($script:ReleasesPresent) {
            [pscustomobject] @{
                Version = '8.0.100'; VersionInfo = New-SdkVersionInfo -Text '8.0.100'
                Rid = $Rid; Url = 'https://example.invalid/sdk.exe'
                Hash = 'A' * 128; HashAlgorithm = 'SHA512'
            }
        }
    }
    function Get-ChannelRuntimeInstallers {
        param($ChannelEntry, $Rid, $ProductType, $MetadataCache)
        if ($script:ReleasesPresent) {
            [pscustomobject] @{
                Version = '8.0.1'; VersionInfo = New-SdkVersionInfo -Text '8.0.1'
                Rid = $Rid; Url = 'https://example.invalid/runtime.exe'
                Hash = 'A' * 128; HashAlgorithm = 'SHA512'
            }
        }
    }
    function Get-UpdateCandidates { return @() }
    function Get-RuntimeUpdateCandidates { return @() }
    function Start-Process { throw 'Empty results must not start a process.' }
    function Save-InstallersInParallel { throw 'Empty results must not download installers.' }
    function Select-UpdateCandidates { throw 'Empty results must not show a checklist.' }
    function Read-Host { throw 'Empty results must not prompt.' }

    $inventoryCases = @(
        @{ Command = 'Get-DotNetInstallation'; Parameters = @{};
            Message = 'No Windows installer-managed .NET installations were found.' }
        @{ Command = 'Get-DotNetInstallation'; Parameters = @{ ProductType = 'Runtime' };
            Message = 'No Windows installer-managed .NET installations were found.' }
        @{ Command = 'Update-DotNetSdk'; Parameters = @{ UpdateAll = $true };
            Message = 'No standalone .NET SDK installer registrations were found.' }
        @{ Command = 'Update-DotNetSdk'; Parameters = @{ VersionBand = '8.0' };
            Message = 'No standalone .NET SDK installer registrations were found.' }
        @{ Command = 'Update-DotNetRuntime'; Parameters = @{ UpdateAll = $true };
            Message = 'No matching standalone .NET runtime installer registrations were found.' }
        @{ Command = 'Update-DotNetRuntime'; Parameters = @{ VersionBand = '8.0' };
            Message = 'No matching standalone .NET runtime installer registrations were found.' }
    )
    foreach ($command in @('Uninstall-DotNetSdk', 'Uninstall-DotNetRuntime')) {
        foreach ($parameters in @(@{}, @{ UninstallAll = $true }, @{ VersionBand = '8.0' })) {
            $inventoryCases += @{
                Command = $command; Parameters = $parameters
                Message = 'No matching uninstallable standalone .NET installations were found.'
            }
        }
    }
    $noInventoryFeedback = $true
    foreach ($case in $inventoryCases) {
        $parameters = $case.Parameters
        $messages = @()
        $data = @(& $case.Command @parameters -InformationVariable messages)
        $text = @($messages | ForEach-Object { [string] $_.MessageData }) -join "`n"
        $noInventoryFeedback = $noInventoryFeedback -and
            $data.Count -eq 0 -and $text.Contains($case.Message)
    }
    $noInventoryNetworkSafe = $script:MetadataRequests -eq 0
    $script:InventoryPresent = $true
    $filterCases = @(
        @{ Command = 'Get-DotNetInstallation'; Parameters = @{ ProductType = 'WindowsDesktopRuntime' };
            Message = 'No Windows installer-managed .NET installations matched the requested filters.' }
        @{ Command = 'Get-DotNetInstallation'; Parameters = @{ Architecture = 'arm64' };
            Message = 'No Windows installer-managed .NET installations matched the requested filters.' }
        @{ Command = 'Get-DotNetInstallation'; Parameters = @{ ManagementSource = 'VisualStudio' };
            Message = 'No Windows installer-managed .NET installations matched the requested filters.' }
        @{ Command = 'Update-DotNetSdk'; Parameters = @{ VersionBand = '99.0' };
            Message = 'No installed .NET SDKs matched -VersionBand: 99.0.' }
        @{ Command = 'Update-DotNetRuntime'; Parameters = @{ VersionBand = '99.0' };
            Message = 'No standalone .NET runtimes matched -VersionBand: 99.0.' }
    )
    foreach ($command in @('Uninstall-DotNetSdk', 'Uninstall-DotNetRuntime')) {
        foreach ($parameters in @(
            @{ VersionBand = '99.0' },
            @{ Architecture = 'arm64'; UninstallAll = $true },
            @{ Architecture = 'arm64'; VersionBand = '8.0' }
        )) {
            $filterCases += @{
                Command = $command; Parameters = $parameters
                Message = 'No matching uninstallable standalone .NET installations were found.'
            }
        }
    }
    $filterFeedback = $true
    foreach ($case in $filterCases) {
        $parameters = $case.Parameters
        $messages = @()
        $data = @(& $case.Command @parameters -InformationVariable messages)
        $text = @($messages | ForEach-Object { [string] $_.MessageData }) -join "`n"
        $filterFeedback = $filterFeedback -and
            $data.Count -eq 0 -and $text.Contains($case.Message)
    }
    $filteredInventoryNetworkSafe = $script:MetadataRequests -eq 0
    $updateFeedback = $true
    foreach ($command in @('Update-DotNetSdk', 'Update-DotNetRuntime')) {
        $messages = @()
        $data = @(& $command -UpdateAll -InformationVariable messages)
        $text = @($messages | ForEach-Object { [string] $_.MessageData }) -join "`n"
        $updateFeedback = $updateFeedback -and $data.Count -eq 0 -and
            $text -match 'No eligible .*updates were found within .* scope\.'
    }
    $findFeedback = $true
    $successfulFindData = $true
    foreach ($command in @('Find-DotNetSdk', 'Find-DotNetRuntime')) {
        foreach ($parameters in @(
            @{ Channel = 8 }, @{ Channel = 8; IncludePreview = $true }, @{ Version = '8.0.100' }
        )) {
            $messages = @()
            $data = @(& $command @parameters -Architecture x64 -InformationVariable messages)
            $text = @($messages | ForEach-Object { [string] $_.MessageData }) -join "`n"
            $expectedHint = $parameters.ContainsKey('Channel') -and
                -not $parameters.ContainsKey('IncludePreview')
            $findFeedback = $findFeedback -and $data.Count -eq 0 -and
                $text -match 'No official Windows .NET .* releases matched the requested filters\.' -and
                ($text.Contains('Use -IncludePreview') -eq $expectedHint)
        }
        $script:ReleasesPresent = $true
        $messages = @()
        $data = @(& $command -Channel 8 -Architecture x64 -InformationVariable messages)
        $successfulFindData = $successfulFindData -and $data.Count -gt 0 -and
            $messages.Count -eq 0 -and $data[0].PSTypeNames[0] -eq 'DotNetSteward.AvailableRelease'
        $script:ReleasesPresent = $false
    }
    $installRefused = $true
    foreach ($command in @('Install-DotNetSdk', 'Install-DotNetRuntime')) {
        foreach ($parameters in @(@{ Channel = 8 }, @{ Version = '8.0.100' })) {
            $refused = $false
            try {
                & $command @parameters -Architecture x64 -WhatIf
            }
            catch {
                $refused = $_.Exception.Message -match 'No official x64 .* EXE installer was found'
            }
            $installRefused = $installRefused -and $refused
        }
    }
    $script:InventoryPresent = $false
    $invalidUninstallSelectorRefused = $true
    foreach ($command in @('Uninstall-DotNetSdk', 'Uninstall-DotNetRuntime')) {
        $refused = $false
        try { & $command -VersionBand 'invalid' }
        catch { $refused = $_.Exception.Message -like 'Invalid version-band selector*' }
        $invalidUninstallSelectorRefused = $invalidUninstallSelectorRefused -and $refused
    }
    [pscustomobject] @{
        NoInventoryFeedback = $noInventoryFeedback; NoInventoryNetworkSafe = $noInventoryNetworkSafe
        FilterFeedback = $filterFeedback; FilteredInventoryNetworkSafe = $filteredInventoryNetworkSafe
        UpdateFeedback = $updateFeedback; FindFeedback = $findFeedback
        SuccessfulFindData = $successfulFindData; InstallRefused = $installRefused
        InvalidUninstallSelectorRefused = $invalidUninstallSelectorRefused
    }
}
foreach ($property in $emptyResultChecks.PSObject.Properties) {
    Assert-Condition $property.Value "Empty-result check '$($property.Name)' failed."
}

Write-Host 'Checking installation support status...'
$supportChecks = & $module {
    $releaseIndex = @(
        [pscustomobject] @{
            'channel-version' = '10.0'; 'support-phase' = 'active'
            'latest-sdk' = '10.0.401'; 'latest-runtime' = '10.0.12'
            'eol-date' = '2999-11-14'; 'releases.json' = 'https://example.test/10.0.json'
        }
        [pscustomobject] @{
            'channel-version' = '11.0'; 'support-phase' = 'go-live'
            'latest-sdk' = '11.0.100-preview.10.2'; 'latest-runtime' = '11.0.0-preview.10.2'
        }
        [pscustomobject] @{
            'channel-version' = '8.0'; 'support-phase' = 'maintenance'
            'latest-sdk' = '8.0.425'; 'latest-runtime' = '8.0.31'
        }
        [pscustomobject] @{
            'channel-version' = '7.0'; 'support-phase' = 'eol'
            'latest-sdk' = '7.0.410'; 'latest-runtime' = '7.0.20'
        }
        [pscustomobject] @{
            'channel-version' = '2.1'; 'support-phase' = 'eol'
            'latest-sdk' = '2.1.818'; 'releases.json' = 'https://example.test/2.1.json'
        }
        [pscustomobject] @{
            'channel-version' = '2.0'; 'support-phase' = 'eol'
            'latest-sdk' = '2.1.202'; 'releases.json' = 'https://example.test/2.0.json'
        }
        [pscustomobject] @{
            'channel-version' = '12.0'; 'support-phase' = 'unrecognized'
        }
        [pscustomobject] @{
            'channel-version' = '13.0'; 'support-phase' = 'active'
            'eol-date' = '2000-01-01'
        }
        [pscustomobject] @{
            'channel-version' = '14.0'; 'support-phase' = 'active'
            'latest-runtime' = 'invalid'
        }
        [pscustomobject] @{
            'channel-version' = '15.0'; 'support-phase' = 'preview'
            'latest-runtime' = '15.0.0-preview.2'
        }
    )
    $requests = New-Object System.Collections.Generic.List[string]
    $failure = ''
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers)

        $requests.Add([string] $Uri)
        if ($failure -eq 'index') {
            throw 'Synthetic offline failure'
        }
        if ($Uri -eq $script:ReleaseIndexUri) {
            return [pscustomobject] @{ 'releases-index' = $releaseIndex }
        }
        if ($failure -eq 'channel') {
            throw 'Synthetic channel failure'
        }
        switch ($Uri) {
            'https://example.test/10.0.json' {
                return [pscustomobject] @{
                    releases = @(
                        [pscustomobject] @{ sdk = [pscustomobject] @{ version = '10.0.101' } }
                        [pscustomobject] @{ sdks = @(
                            [pscustomobject] @{ version = '10.0.111' }
                            [pscustomobject] @{ version = '10.0.401' }
                            [pscustomobject] @{ version = '10.0.110' }
                        ) }
                    )
                }
            }
            'https://example.test/2.1.json' {
                return [pscustomobject] @{
                    releases = @([pscustomobject] @{ sdk = [pscustomobject] @{ version = '2.1.818' } })
                }
            }
            'https://example.test/2.0.json' {
                return [pscustomobject] @{
                    releases = @([pscustomobject] @{ sdk = [pscustomobject] @{ version = '2.1.202' } })
                }
            }
            default { throw "Unexpected metadata request: $Uri" }
        }
    }
    function New-TestInstallation {
        param($ProductType, $Version, $Architecture = 'x64')

        [pscustomobject] @{
            PSTypeName = 'DotNetSteward.Installation'
            ProductType = $ProductType
            Version = $Version
            VersionInfo = New-SdkVersionInfo -Text $Version
            Architecture = $Architecture
            ManagementSource = 'VisualStudio'
            ManagedByVisualStudio = $true
            IsUpdateable = $false
            IsUninstallable = $false
        }
    }
    function Get-DotNetInstallationInventory { return $testInventory }

    $cases = @(
        @('Sdk', '10.0.101', 'Patch 10.0.111 is available.'),
        @('Sdk', '10.0.111', 'Up to date.'),
        @('Sdk', '10.0.401', 'Up to date.'),
        @('Sdk', '10.0.402', 'Up to date.'),
        @('Sdk', '11.0.100-preview.2.10', 'Patch 11.0.100-preview.10.2 is available.'),
        @('Sdk', '8.0.100', '.NET 8.0 is going out of support soon.'),
        @('Sdk', '7.0.100', '.NET 7.0 is out of support.'),
        @('Sdk', '2.1.202', '.NET 2.0 is out of support.'),
        @('Runtime', '10.0.1', 'Patch 10.0.12 is available.'),
        @('Runtime', '10.0.12', 'Up to date.'),
        @('AspNetCoreRuntime', '10.0.1', 'Patch 10.0.12 is available.'),
        @('WindowsDesktopRuntime', '10.0.1', 'Patch 10.0.12 is available.'),
        @('Runtime', '8.0.1', '.NET 8.0 is going out of support soon.'),
        @('Runtime', '7.0.1', '.NET 7.0 is out of support.'),
        @('Runtime', '13.0.0', '.NET 13.0 is out of support.'),
        @('Runtime', '11.0.0-preview.2.10', 'Patch 11.0.0-preview.10.2 is available.'),
        @('Runtime', '11.0.0', 'Up to date.'),
        @('Runtime', '15.0.0-preview.2', 'Up to date.')
    )
    $testInventory = @(
        foreach ($case in $cases) {
            New-TestInstallation $case[0] $case[1]
        }
        New-TestInstallation 'Sdk' '10.0.101' 'x86'
        New-TestInstallation 'Runtime' '10.0.12' 'arm64'
    )
    $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
    $items = @(Get-DotNetInstallation)
    foreach ($case in $cases) {
        $item = @($items | Where-Object {
            $_.ProductType -eq $case[0] -and $_.Version -eq $case[1]
        })[0]
        if ($item.SupportStatus -ne $case[2]) {
            throw "Unexpected status for $($case[0]) $($case[1]): $($item.SupportStatus)"
        }
        if ($item.IsUpdateable -or $item.IsUninstallable -or -not $item.ManagedByVisualStudio) {
            throw 'Support status changed installation ownership or actionability.'
        }
    }
    if (@($requests | Where-Object { $_ -eq $script:ReleaseIndexUri }).Count -ne 1 -or
        @($requests | Where-Object { $_ -eq 'https://example.test/10.0.json' }).Count -ne 1) {
        throw 'Support checks did not cache release metadata across feature bands and architectures.'
    }
    $currentSdk = @($items | Where-Object { $_.Version -eq '10.0.401' })[0]
    if ($currentSdk.LatestPatchVersion -ne '10.0.401' -or $currentSdk.SupportPhase -ne 'active' -or
        $currentSdk.EndOfSupportDate -ne [datetime] '2999-11-14') {
        throw 'Support status did not expose structured lifecycle and patch metadata.'
    }
    if (@($items | Where-Object Version -eq '2.1.202')[0].Channel -ne '2.0') {
        throw 'A historical SDK was mapped to the wrong catalog channel.'
    }
    if (@($items | Where-Object {
        $_.Architecture -eq 'x86' -and $_.SupportStatus -eq 'Patch 10.0.111 is available.'
    }).Count -ne 1 -or @($items | Where-Object {
        $_.Architecture -eq 'arm64' -and $_.SupportStatus -eq 'Up to date.'
    }).Count -ne 1) {
        throw 'Support status was not applied across architectures.'
    }

    $testInventory = @(
        New-TestInstallation 'Runtime' '99.0.0'
        New-TestInstallation 'Runtime' '12.0.0'
        New-TestInstallation 'Runtime' '14.0.0'
        New-TestInstallation 'Sdk' '10.0.999'
        New-TestInstallation 'Runtime' '10.0.12'
    )
    $warnings = @()
    $unknownItems = @(Get-DotNetInstallation -WarningVariable warnings -WarningAction SilentlyContinue)
    if ($warnings.Count -ne 4 -or
        @($unknownItems | Where-Object SupportStatus -eq 'Unknown').Count -ne 4 -or
        @($unknownItems | Where-Object SupportStatus -eq 'Up to date.').Count -ne 1) {
        throw 'Unknown channels, feature bands, or invalid metadata did not warn and preserve inventory.'
    }

    $failure = 'index'
    $warnings = @()
    $offlineItems = @(Get-DotNetInstallation -WarningVariable warnings -WarningAction SilentlyContinue)
    if ($warnings.Count -ne 1 -or $offlineItems.Count -ne $testInventory.Count -or
        @($offlineItems | Where-Object SupportStatus -ne 'Unknown').Count -ne 0) {
        throw 'Offline support checks did not warn and preserve all local inventory.'
    }

    $failure = 'channel'
    $testInventory = @(
        New-TestInstallation 'Sdk' '10.0.101'
        New-TestInstallation 'Runtime' '10.0.12'
    )
    $warnings = @()
    $partialItems = @(Get-DotNetInstallation -WarningVariable warnings -WarningAction SilentlyContinue)
    if ($warnings.Count -ne 1 -or
        @($partialItems | Where-Object SupportStatus -eq 'Unknown').Count -ne 1 -or
        @($partialItems | Where-Object SupportStatus -eq 'Up to date.').Count -ne 1) {
        throw 'A failed channel lookup prevented independent support checks.'
    }
    if ([Net.ServicePointManager]::SecurityProtocol -ne $originalProtocol) {
        throw 'Support checks did not restore the process security protocol.'
    }

    $requests.Clear()
    $skippedItems = @(Get-DotNetInstallation -SkipSupportCheck)
    if ($requests.Count -ne 0 -or
        @($skippedItems | Where-Object SupportStatus -ne 'Not checked').Count -ne 0) {
        throw 'SkipSupportCheck did not bypass online metadata.'
    }
    $filteredItems = @(Get-DotNetInstallation -ProductType Runtime -Architecture x64 `
        -ManagementSource VisualStudio)
    if ($filteredItems.Count -ne 1 -or $filteredItems[0].SupportStatus -ne 'Up to date.' -or
        $requests.Count -ne 1) {
        throw 'Support status did not honor inventory filters before looking up metadata.'
    }
    $requests.Clear()
    $emptyItems = @(Get-DotNetInstallation -Architecture arm64)
    $testInventory = @()
    $noItems = @(Get-DotNetInstallation)
    if ($requests.Count -ne 0 -or $emptyItems.Count -ne 0 -or $noItems.Count -ne 0) {
        throw 'Empty or fully filtered inventory performed a metadata lookup.'
    }

    [pscustomobject] @{ Example = $currentSdk }
}
$formattedInstallation = $supportChecks.Example | Format-Table | Out-String -Width 240
$expectedDaysToEol = [int] [math]::Ceiling(
    ($supportChecks.Example.EndOfSupportDate - [datetime]::Now).TotalDays
)
Assert-Condition ($formattedInstallation -match 'EOL date\s+Days to EOL\s+Status' -and
    $formattedInstallation -match "2999-11-14\s+$expectedDaysToEol\s+Up to date\.") `
    'The default installation view does not display the EOL date and day count before support status.'
foreach ($dayCountCase in @(
    @{ Date = [datetime]::Now.AddDays(2.25); Expected = 3 }
    @{ Date = [datetime]::Now.AddDays(-2.25); Expected = -2 }
    @{ Date = [datetime]::Today; Expected = 0 }
)) {
    $datedInstallation = $supportChecks.Example.PSObject.Copy()
    $datedInstallation.EndOfSupportDate = $dayCountCase.Date
    $formattedDatedInstallation = $datedInstallation | Format-Table | Out-String -Width 240
    Assert-Condition (
        $formattedDatedInstallation -match "\d{4}-\d{2}-\d{2}\s+$($dayCountCase.Expected)\s+Up to date\."
    ) "The EOL day count was not rounded up to $($dayCountCase.Expected)."
}
$undatedInstallation = $supportChecks.Example.PSObject.Copy()
$undatedInstallation.EndOfSupportDate = $null
$formattedUndatedInstallation = $undatedInstallation | Format-Table | Out-String -Width 240
Assert-Condition ($formattedUndatedInstallation -match 'False\s+Up to date\.') `
    'The default installation view does not leave an unavailable EOL date and day count blank.'

Write-Host 'Checking the installed-product inventory...'
$installations = @(Get-DotNetInstallation -SkipSupportCheck:$SkipOnlineChecks)
foreach ($installation in $installations) {
    foreach ($propertyName in @(
        'ProductType',
        'Version',
        'Architecture',
        'ManagementSource',
        'ManagedByVisualStudio',
        'IsUpdateable',
        'IsUninstallable',
        'SupportStatus',
        'SupportPhase',
        'Channel',
        'EndOfSupportDate',
        'LatestPatchVersion'
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

Write-Host 'Checking uninstall selection, confirmation, and execution...'
$uninstallCheck = & $module {
    $script:PromptCount = 0
    $script:PlanCount = 0
    $script:Selected = @()
    $script:Answer = 'n'
    $script:Started = @()
    $script:ExitCode = 3010
    $script:SelectionCount = 0
    $script:SignatureValid = $true

    $sdk = [pscustomobject] @{
        ProductType = 'Sdk'; Version = '8.0.425'
        VersionInfo = New-SdkVersionInfo -Text '8.0.425'
        Architecture = 'x64'; Rid = 'win-x64'; InstallerKind = 'Bundle'
        IsUninstallable = $true; DisplayName = 'Microsoft .NET SDK 8.0.425 (x64)'
        BundleCachePath = 'C:\cache\dotnet-sdk.exe'; UninstallString = ''
    }
    $runtime = [pscustomobject] @{
        ProductType = 'Runtime'; Version = '8.0.31'
        VersionInfo = New-SdkVersionInfo -Text '8.0.31'
        Architecture = 'x64'; Rid = 'win-x64'; InstallerKind = 'Bundle'
        IsUninstallable = $true; DisplayName = 'Microsoft .NET Runtime 8.0.31 (x64)'
        BundleCachePath = 'C:\cache\dotnet-runtime.exe'; UninstallString = ''
    }
    $readOnly = [pscustomobject] @{
        ProductType = 'Sdk'; Version = '8.0.424'
        VersionInfo = New-SdkVersionInfo -Text '8.0.424'
        Architecture = 'x64'; Rid = 'win-x64'; InstallerKind = 'Bundle'
        IsUninstallable = $false; DisplayName = 'Visual Studio SDK'
    }
    $payload = [pscustomobject] @{
        ProductType = 'Runtime'; Version = '8.0.30'
        VersionInfo = New-SdkVersionInfo -Text '8.0.30'
        Architecture = 'x64'; Rid = 'win-x64'; InstallerKind = 'Payload'
        IsUninstallable = $false; DisplayName = 'Shared MSI Runtime'
    }
    function Get-DotNetInstallationInventory { return @($sdk, $runtime, $readOnly, $payload) }
    function Read-Host { param($Prompt) $script:PromptCount++; return $script:Answer }
    function Invoke-DotNetUninstallPlan {
        param([object[]] $Installations)
        $script:PlanCount++
        $script:Selected = @($Installations)
    }
    function Select-UpdateCandidates {
        param([object[]] $Candidates, [string] $Action)
        $script:SelectionCount++
        if ($Action -ne 'uninstall') { throw 'Incorrect checklist action.' }
        return @($Candidates | Where-Object ProductType -eq 'Sdk')
    }

    Uninstall-DotNetSdk -VersionBand 8.0 -WhatIf
    $whatIfSafe = $script:PlanCount -eq 0 -and $script:PromptCount -eq 0

    Uninstall-DotNetSdk -UninstallAll
    $declined = $script:PlanCount -eq 0 -and $script:PromptCount -eq 1

    $script:Answer = 'yes'
    Uninstall-DotNetSdk -VersionBand 8.0.4xx
    $confirmed = $script:PlanCount -eq 1 -and
        $script:Selected.Count -eq 1 -and
        $script:Selected[0].Version -eq '8.0.425'

    Uninstall-DotNetRuntime -ProductType Runtime -Architecture x64 -UninstallAll -Force
    $forced = $script:PlanCount -eq 2 -and $script:PromptCount -eq 2 -and
        $script:Selected.Count -eq 1 -and $script:Selected[0].ProductType -eq 'Runtime'

    Uninstall-DotNetSdk -Force
    $interactive = $script:SelectionCount -eq 1 -and $script:PlanCount -eq 3

    function Get-DotNetUninstallExecutable {
        param($Installation)
        return $Installation.BundleCachePath
    }
    function Assert-InstallerSignature {
        param($InstallerPath, $ProductLabel, $Version)
        if (-not $script:SignatureValid) { throw 'Invalid installer signature.' }
        return [pscustomobject] @{ SignerSubject = '.NET' }
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch] $Wait, [switch] $PassThru)
        $script:Started += [pscustomobject] @{
            FilePath = $FilePath; Arguments = @($ArgumentList); Verb = $Verb
        }
        return [pscustomobject] @{ ExitCode = $script:ExitCode }
    }
    Remove-Item Function:Invoke-DotNetUninstallPlan
    [void] (Invoke-DotNetUninstallPlan -Installations @($sdk))
    $executed = $script:Started.Count -eq 1 -and
        $script:Started[0].FilePath -eq $sdk.BundleCachePath -and
        $script:Started[0].Verb -eq 'RunAs' -and
        ($script:Started[0].Arguments -join ' ') -eq '/uninstall /quiet /norestart'

    $script:ExitCode = 1603
    $failed = $false
    try {
        [void] (Invoke-DotNetUninstallPlan -Installations @($sdk))
    }
    catch {
        $failed = $_.Exception.Message -match 'exited with code 1603'
    }

    $script:SignatureValid = $false
    $signatureRefused = $false
    try {
        [void] (Invoke-DotNetUninstallPlan -Installations @($sdk))
    }
    catch {
        $signatureRefused = $_.Exception.Message -match 'Invalid installer signature' -and
            $script:Started.Count -eq 2
    }

    Remove-Item Function:Get-DotNetUninstallExecutable
    $cacheDirectory = Join-Path ([IO.Path]::GetTempPath()) `
        ('dotnet-steward-verify-' + [guid]::NewGuid().ToString('N'))
    [void] (New-Item -Path $cacheDirectory -ItemType Directory)
    try {
        $goodPath = Join-Path $cacheDirectory 'dotnet-sdk-8.0.425-win-x64.exe'
        $wrongPath = Join-Path $cacheDirectory 'dotnet-sdk-9.0.100-win-x64.exe'
        [void] (New-Item -Path $goodPath -ItemType File)
        [void] (New-Item -Path $wrongPath -ItemType File)
        $sdk.BundleCachePath = ''
        $sdk.UninstallString = "`"$goodPath`" /uninstall"
        $pathValid = (Get-DotNetUninstallExecutable -Installation $sdk) -eq $goodPath
        $sdk.BundleCachePath = $wrongPath
        $wrongRefused = $false
        try {
            [void] (Get-DotNetUninstallExecutable -Installation $sdk)
        }
        catch {
            $wrongRefused = $_.Exception.Message -match 'does not match'
        }
        $sdk.BundleCachePath = Join-Path $cacheDirectory 'missing.exe'
        $missingRefused = $false
        try {
            [void] (Get-DotNetUninstallExecutable -Installation $sdk)
        }
        catch {
            $missingRefused = $_.Exception.Message -match 'not found'
        }
    }
    finally {
        Remove-Item -LiteralPath $cacheDirectory -Recurse -Force
    }

    [pscustomobject] @{
        WhatIfSafe = $whatIfSafe; Declined = $declined
        Confirmed = $confirmed; Forced = $forced
        Interactive = $interactive; Executed = $executed; Failed = $failed
        SignatureRefused = $signatureRefused
        PathValid = $pathValid; WrongRefused = $wrongRefused; MissingRefused = $missingRefused
    }
}
foreach ($propertyName in @('WhatIfSafe', 'Declined', 'Confirmed', 'Forced',
    'Interactive', 'Executed', 'Failed', 'SignatureRefused', 'PathValid',
    'WrongRefused', 'MissingRefused')) {
    Assert-Condition $uninstallCheck.$propertyName "Uninstall check '$propertyName' failed."
}

Write-Host 'Checking batch elevation and explicit overrides...'
$elevationChecks = & $module {
    $script:Administrator = $false
    $script:Started = @()
    $script:Elevated = @()
    $script:ExitCode = 0
    $script:SignatureValid = $true
    function Test-DotNetAdministrator { return $script:Administrator }
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch] $Wait, [switch] $PassThru)
        $script:Started += [pscustomobject] @{
            Path = $FilePath; Arguments = @($ArgumentList); Verb = $Verb
        }
        return [pscustomobject] @{ ExitCode = $script:ExitCode }
    }
    function Invoke-DotNetElevatedOperation {
        param($Action, $Items, $ShowInstallerUi)
        $script:Elevated += [pscustomobject] @{
            Action = $Action; Items = @($Items); ShowInstallerUi = $ShowInstallerUi
        }
        return $true
    }
    function Assert-InstallerTrust {
        param($Candidate)
        if (-not $script:SignatureValid) { throw 'Invalid installer trust.' }
        return [pscustomobject] @{ SignerSubject = '.NET' }
    }
    function Get-DotNetUninstallExecutable {
        param($Installation)
        return $Installation.BundleCachePath
    }
    function Assert-InstallerSignature {
        param($InstallerPath, $ProductLabel, $Version)
        if (-not $script:SignatureValid) { throw 'Invalid installer signature.' }
    }
    $items = @(
        foreach ($version in @('10.0.2', '8.0.31')) {
            [pscustomobject] @{
                ProductType = 'Runtime'; ProductLabel = '.NET Runtime'
                Version = $version; TargetVersion = $version
                VersionInfo = New-SdkVersionInfo -Text $version
                TargetVersionInfo = New-SdkVersionInfo -Text $version
                Architecture = 'x64'; Rid = 'win-x64'
                InstallerPath = "C:\fake\$version.exe"
                BundleCachePath = "C:\fake\$version.exe"
                DisplayName = ".NET Runtime $version"
                InstallerKind = 'Bundle'; IsUninstallable = $true
                RegistryView = 'Registry32'; RegistrySubkey = "fake\$version"
                BundleId = $version
            }
        }
    )

    [void] (Install-DotNetCandidates -Candidates @($items[0]) -ShowInstallerUi $false)
    $singleDirect = $script:Started.Count -eq 1 -and $script:Elevated.Count -eq 0
    $restart = Install-DotNetCandidates -Candidates $items -ShowInstallerUi $true
    $batchElevated = $restart -and $script:Elevated.Count -eq 1 -and
        $script:Started.Count -eq 1 -and $script:Elevated[0].ShowInstallerUi -and
        $script:Elevated[0].Items[0].TargetVersion -eq '8.0.31'
    [void] (Install-DotNetCandidates -Candidates $items -ShowInstallerUi $false -Elevate:$false)
    $batchOptOut = $script:Started.Count -eq 3 -and $script:Elevated.Count -eq 1 -and
        ($script:Started[1].Arguments -join ' ') -eq '/install /quiet /norestart'
    [void] (Install-DotNetCandidates -Candidates @($items[0]) -ShowInstallerUi $false -Elevate:$true)
    $singleOptIn = $script:Elevated.Count -eq 2
    $script:Administrator = $true
    [void] (Install-DotNetCandidates -Candidates $items -ShowInstallerUi $true -Elevate:$true)
    $alreadyElevated = $script:Elevated.Count -eq 2 -and $script:Started.Count -eq 5 -and
        ($script:Started[3].Arguments -join ' ') -eq '/install /norestart'
    $script:Administrator = $false
    $restart = Invoke-DotNetUninstallPlan -Installations $items
    $uninstallBatch = $restart -and $script:Elevated.Count -eq 3 -and
        $script:Elevated[2].Action -eq 'Uninstall'
    [void] (Invoke-DotNetUninstallPlan -Installations $items -Elevate:$false)
    $uninstallOptOut = $script:Started.Count -eq 7 -and $script:Elevated.Count -eq 3
    [void] (Invoke-DotNetUninstallPlan -Installations @($items[0]) -Elevate:$true)
    $uninstallOptIn = $script:Elevated.Count -eq 4
    [void] (Invoke-DotNetUninstallPlan -Installations @($items[0]))
    $uninstallSingle = $script:Started.Count -eq 8 -and $script:Elevated.Count -eq 4
    $script:Administrator = $true
    $script:ExitCode = 1603
    $stopOnFailure = $false
    try {
        [void] (Install-DotNetCandidates -Candidates $items -ShowInstallerUi $false)
    }
    catch {
        $stopOnFailure = $_.Exception.Message -match 'exited with code 1603' -and
            $script:Started.Count -eq 9
    }

    $directory = Join-Path ([IO.Path]::GetTempPath()) (
        'dotnet-steward-worker-test-' + [guid]::NewGuid().ToString('N')
    )
    [void] (New-Item -Path $directory -ItemType Directory)
    try {
        $planPath = Join-Path $directory 'plan.clixml'
        $resultPath = Join-Path $directory 'result.clixml'
        [pscustomobject] @{
            Action = 'Install'; Items = $items; ShowInstallerUi = $true
        } | Export-Clixml -LiteralPath $planPath
        $script:ExitCode = 3010
        $code = Invoke-DotNetElevationWorker -PlanPath $planPath -ResultPath $resultPath
        $result = Import-Clixml -LiteralPath $resultPath
        $workerSucceeded = $code -eq 0 -and $result.Succeeded -and $result.RestartRequired -and
            $script:Started.Count -eq 11 -and $script:Elevated.Count -eq 4
        $script:SignatureValid = $false
        $code = Invoke-DotNetElevationWorker -PlanPath $planPath -ResultPath $resultPath `
            -ErrorAction SilentlyContinue 2>$null
        $result = Import-Clixml -LiteralPath $resultPath
        $workerTrustRefused = $code -eq 1 -and -not $result.Succeeded -and
            $result.Error -eq 'Invalid installer trust.' -and $script:Started.Count -eq 11
        $script:SignatureValid = $true
        function Get-DotNetInstallationInventory {
            [pscustomobject] @{ InstallerKind = 'Payload'; IsUninstallable = $false }
            $items
        }
        [pscustomobject] @{
            Action = 'Uninstall'; Items = $items
        } | Export-Clixml -LiteralPath $planPath
        $code = Invoke-DotNetElevationWorker -PlanPath $planPath -ResultPath $resultPath
        $result = Import-Clixml -LiteralPath $resultPath
        $uninstallWorkerSucceeded = $code -eq 0 -and $result.Succeeded -and
            $result.RestartRequired -and $script:Started.Count -eq 13
        $items[1].IsUninstallable = $false
        $code = Invoke-DotNetElevationWorker -PlanPath $planPath -ResultPath $resultPath 2>$null
        $result = Import-Clixml -LiteralPath $resultPath
        $ownershipRechecked = $code -eq 1 -and -not $result.Succeeded -and
            $result.Error -match 'no longer uniquely uninstallable' -and $script:Started.Count -eq 13
        $script:Administrator = $false
        $code = Invoke-DotNetElevationWorker -PlanPath $planPath -ResultPath $resultPath 2>$null
        $result = Import-Clixml -LiteralPath $resultPath
        $workerRequiresAdmin = $code -eq 1 -and -not $result.Succeeded -and
            $result.Error -match 'not running with administrator privileges'
    }
    finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }

    Remove-Item Function:Invoke-DotNetElevatedOperation
    $script:WorkerMode = 'Success'
    $script:WorkerDirectory = ''
    $script:CommandValid = $false
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch] $Wait, [switch] $PassThru)
        $command = [Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($ArgumentList[-1])
        )
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $command, [ref] $tokens, [ref] $errors
        )
        $paths = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Value -like '*.clixml'
        }, $true) | ForEach-Object { $_.Value })
        $script:WorkerDirectory = Split-Path -Parent $paths[0]
        $plan = Import-Clixml -LiteralPath $paths[0]
        $expectedExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $script:CommandValid = @($errors).Count -eq 0 -and $Verb -eq 'RunAs' -and
            $Wait -and $PassThru -and $FilePath -eq (Join-Path $PSHOME $expectedExecutable) -and
            $ArgumentList[0] -eq '-NoLogo' -and $ArgumentList[1] -eq '-NoProfile' -and
            $ArgumentList[3] -eq [string] (Get-ExecutionPolicy) -and
            $plan.Items.Count -eq 2 -and $plan.ShowInstallerUi -and $plan.Action -eq 'Install'
        if ($script:WorkerMode -eq 'Cancel') {
            throw (New-Object ComponentModel.Win32Exception(1223))
        }
        if ($script:WorkerMode -ne 'MissingResult') {
            [pscustomobject] @{
                Succeeded = $script:WorkerMode -eq 'Success'
                RestartRequired = $true
                Error = 'Synthetic installer failure.'
            } | Export-Clixml -LiteralPath $paths[1]
        }
        return [pscustomobject] @{
            ExitCode = if ($script:WorkerMode -eq 'Success') { 0 } else { 1 }
        }
    }
    $restart = Invoke-DotNetElevatedOperation -Action Install -Items $items -ShowInstallerUi $true
    $handoffValid = $restart -and $script:CommandValid -and
        -not (Test-Path -LiteralPath $script:WorkerDirectory)
    $failureChecks = @()
    foreach ($mode in @('Cancel', 'Failure', 'MissingResult')) {
        $script:WorkerMode = $mode
        $failed = $false
        try {
            [void] (Invoke-DotNetElevatedOperation -Action Install -Items $items -ShowInstallerUi $true)
        }
        catch {
            $pattern = switch ($mode) {
                'Cancel' { 'Administrator approval was cancelled' }
                'Failure' { 'Synthetic installer failure' }
                'MissingResult' { 'without reporting a result' }
            }
            $failed = $_.Exception.Message -match $pattern -and
                -not (Test-Path -LiteralPath $script:WorkerDirectory)
        }
        $failureChecks += $failed
    }
    [pscustomobject] @{
        SingleDirect = $singleDirect; BatchElevated = $batchElevated
        BatchOptOut = $batchOptOut; SingleOptIn = $singleOptIn
        AlreadyElevated = $alreadyElevated; StopOnFailure = $stopOnFailure
        UninstallBatch = $uninstallBatch; UninstallOptOut = $uninstallOptOut
        UninstallOptIn = $uninstallOptIn; UninstallSingle = $uninstallSingle
        WorkerSucceeded = $workerSucceeded; WorkerTrustRefused = $workerTrustRefused
        UninstallWorkerSucceeded = $uninstallWorkerSucceeded
        OwnershipRechecked = $ownershipRechecked; WorkerRequiresAdmin = $workerRequiresAdmin
        HandoffValid = $handoffValid; FailuresAndCleanup = -not ($failureChecks -contains $false)
    }
}
foreach ($property in $elevationChecks.PSObject.Properties) {
    Assert-Condition $property.Value "Elevation check '$($property.Name)' failed."
}

Write-Host 'Checking elevation forwarding and WhatIf safety...'
$elevationForwardingChecks = & $module {
    $script:Plans = @()
    $script:SelectedCount = 0
    $script:Prompts = 0
    $script:Administrator = $false
    $script:OperationCount = 2
    $item = [pscustomobject] @{
        ProductType = 'Runtime'; ProductLabel = '.NET Runtime'
        Version = '8.0.31'; TargetVersion = '8.0.32'
        VersionInfo = New-SdkVersionInfo -Text '8.0.31'
        TargetVersionInfo = New-SdkVersionInfo -Text '8.0.32'
        Architecture = 'x64'; Rid = 'win-x64'; InstallerKind = 'Bundle'
        IsUpdateable = $true; IsUninstallable = $true
    }
    function Find-DotNetSdk { return $item }
    function Find-DotNetRuntime { return $item }
    function Assert-RequestedReleasesResolved {}
    function Test-DotNetAdministrator { return $script:Administrator }
    function ConvertTo-DotNetInstallCandidates { return @($item) * $script:OperationCount }
    function Get-DotNetSdkBundleInventory { return @($item) * $script:OperationCount }
    function Get-DotNetInstallationInventory { return @($item) * $script:OperationCount }
    function Get-ReleaseIndex { return @() }
    function Get-UpdateCandidates { return @($item) * $script:OperationCount }
    function Get-RuntimeUpdateCandidates { return @($item) * $script:OperationCount }
    function Show-AvailableUpdates {}
    function Select-UpdateCandidates { $script:SelectedCount++; return $item }
    function Confirm-SelectedUpdates { return $true }
    function Read-Host { $script:Prompts++; return 'yes' }
    function Invoke-DotNetInstallerPlan {
        param($Candidates, $ShowInstallerUi, $CompletionSubject, [Nullable[bool]] $Elevate)
        $script:Plans += [pscustomobject] @{
            Elevate = $Elevate; Count = @($Candidates).Count
        }
    }
    function Invoke-DotNetUninstallPlan {
        param($Installations, [Nullable[bool]] $Elevate)
        $script:Plans += [pscustomobject] @{
            Elevate = $Elevate; Count = @($Installations).Count
        }
        return $false
    }
    $forwardingValid = $true
    $whatIfSafe = $true
    $previewValid = $true
    foreach ($name in @('Install-DotNetSdk', 'Install-DotNetRuntime',
        'Update-DotNetSdk', 'Update-DotNetRuntime',
        'Uninstall-DotNetSdk', 'Uninstall-DotNetRuntime')) {
        $item.ProductType = if ($name -like '*Sdk') { 'Sdk' } else { 'Runtime' }
        $parameters = @{ Architecture = 'x64' }
        if ($name -like 'Install-*') { $parameters.Version = @('8.0.31') }
        elseif ($name -like 'Update-*') {
            $parameters = @{ UpdateAll = $true }
            if ($name -like '*Runtime') { $parameters.Architecture = 'x64' }
        }
        else { $parameters.UninstallAll = $true; $parameters.Force = $true }
        foreach ($mode in @('Default', 'Enabled', 'Disabled')) {
            $parameters.Remove('Elevate')
            if ($mode -ne 'Default') { $parameters.Elevate = $mode -eq 'Enabled' }
            $before = $script:Plans.Count
            & $name @parameters
            $last = $script:Plans[-1]
            $correctValue = switch ($mode) {
                'Default' { $null -eq $last.Elevate }
                'Enabled' { $last.Elevate -eq $true }
                'Disabled' { $null -ne $last.Elevate -and $last.Elevate -eq $false }
            }
            $forwardingValid = $forwardingValid -and $correctValue -and
                $script:Plans.Count -eq ($before + 1) -and $last.Count -eq 2
        }
        $parameters.Elevate = $true
        $before = $script:Plans.Count
        & $name @parameters -WhatIf
        $whatIfSafe = $whatIfSafe -and $script:Plans.Count -eq $before -and $script:Prompts -eq 0
        foreach ($count in @(1, 3)) {
            $script:OperationCount = $count
            foreach ($administrator in @($false, $true)) {
                $script:Administrator = $administrator
                foreach ($mode in @('Default', 'Enabled', 'Disabled')) {
                    $parameters.Remove('Elevate')
                    if ($mode -ne 'Default') { $parameters.Elevate = $mode -eq 'Enabled' }
                    $before = $script:Plans.Count
                    $output = @(& $name @parameters -WhatIf 6>&1 |
                        ForEach-Object { [string] $_ }) -join "`n"
                    $useWorker = $mode -eq 'Enabled' -or ($mode -eq 'Default' -and $count -gt 1)
                    $expectedMessage = if ($administrator) {
                        'What if: Elevation: no administrator approval request (this PowerShell session is already elevated).'
                    }
                    elseif ($useWorker) {
                        "What if: Elevation: one administrator approval request for $count operation(s) using an elevated PowerShell worker."
                    }
                    else {
                        "What if: Elevation: $count administrator approval request(s), one per installer; no elevated PowerShell worker."
                    }
                    $previewValid = $previewValid -and
                        $output.Contains($expectedMessage) -and
                        @([regex]::Matches($output, 'What if: Elevation:')).Count -eq 1
                    $whatIfSafe = $whatIfSafe -and
                        $script:Plans.Count -eq $before -and $script:Prompts -eq 0
                }
            }
        }
        $script:OperationCount = 2
        $script:Administrator = $false
    }
    $item.ProductType = 'Runtime'
    $script:OperationCount = 0
    $emptyOutput = @(Update-DotNetRuntime -UpdateAll -WhatIf 6>&1 |
        ForEach-Object { [string] $_ }) -join "`n"
    $emptyPreviewSafe = $emptyOutput -notmatch 'What if: Elevation:'
    $script:OperationCount = 2
    Update-DotNetRuntime
    $interactiveCount = $script:Plans[-1].Count -eq 1 -and
        $null -eq $script:Plans[-1].Elevate -and $script:SelectedCount -eq 1
    function Confirm-SelectedUpdates { return $false }
    $before = $script:Plans.Count
    Update-DotNetRuntime -Elevate
    $declinedSafe = $script:Plans.Count -eq $before
    [pscustomobject] @{
        ForwardingValid = $forwardingValid
        WhatIfSafe = $whatIfSafe
        PreviewValid = $previewValid
        EmptyPreviewSafe = $emptyPreviewSafe
        InteractiveCount = $interactiveCount
        DeclinedSafe = $declinedSafe
    }
}
foreach ($property in $elevationForwardingChecks.PSObject.Properties) {
    Assert-Condition $property.Value "Elevation forwarding check '$($property.Name)' failed."
}

Write-Host 'Checking the cross-process elevation result channel without installing...'
$workerStartupCheck = & $module {
    $script:StartupDirectory = ''
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch] $Wait, [switch] $PassThru)
        $command = [Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($ArgumentList[-1])
        )
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $command, [ref] $tokens, [ref] $errors
        )
        $paths = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Value -like '*.clixml'
        }, $true) | ForEach-Object { $_.Value })
        $script:StartupDirectory = Split-Path -Parent $paths[0]
        # Launch the actual encoded worker, but never elevate or provide an executable.
        return Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath `
            -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden
    }
    $refused = $false
    try {
        [void] (Invoke-DotNetElevatedOperation -Action Install -Items @(
            [pscustomobject] @{
                ProductLabel = '.NET Runtime'; TargetVersion = '8.0.31'
                InstallerPath = Join-Path ([IO.Path]::GetTempPath()) (
                    [guid]::NewGuid().ToString('N') + '.missing'
                )
                HashAlgorithm = 'SHA512'; Hash = 'A' * 128
            }
        ))
    }
    catch {
        $refused = $_.Exception.Message -match 'elevated .NET operation failed \(exit code 1\)' -and
            $_.Exception.Message -notmatch 'without reporting a result' -and
            -not (Test-Path -LiteralPath $script:StartupDirectory)
    }
    return $refused
}
Assert-Condition $workerStartupCheck 'The actual worker did not return its failure or clean up.'

Write-Host 'Checking batch download cleanup and pre-elevation trust checks...'
$elevationCleanupCheck = & $module {
    $script:DownloadDirectory = ''
    $script:Mode = 'Success'
    $script:WorkerCalls = 0
    function Test-DotNetAdministrator { return $false }
    function Save-InstallersInParallel {
        param($Candidates, $DestinationDirectory)
        $script:DownloadDirectory = $DestinationDirectory
        if ($script:Mode -eq 'DownloadFailure') { throw 'Synthetic download failure.' }
    }
    function Assert-InstallerTrust {
        param($Candidate)
        if ($script:Mode -eq 'TrustFailure') { throw 'Synthetic trust failure.' }
        return [pscustomobject] @{ SignerSubject = '.NET' }
    }
    function Invoke-DotNetElevatedOperation {
        param($Action, $Items, $ShowInstallerUi)
        $script:WorkerCalls++
        if ($script:Mode -eq 'ElevationFailure') { throw 'Synthetic elevation cancellation.' }
        return $true
    }
    $candidate = [pscustomobject] @{
        ProductLabel = '.NET Runtime'; TargetVersion = '8.0.31'; Rid = 'win-x64'
        TargetVersionInfo = New-SdkVersionInfo -Text '8.0.31'
    }
    $checks = @()
    foreach ($mode in @('Success', 'DownloadFailure', 'TrustFailure', 'ElevationFailure')) {
        $script:Mode = $mode
        $before = $script:WorkerCalls
        $expectedOutcome = $false
        try {
            Invoke-DotNetInstallerPlan -Candidates @($candidate, $candidate) -ShowInstallerUi $false
            $expectedOutcome = $mode -eq 'Success'
        }
        catch {
            $expectedMessage = switch ($mode) {
                'DownloadFailure' { 'Synthetic download failure.' }
                'TrustFailure' { 'Synthetic trust failure.' }
                'ElevationFailure' { 'Synthetic elevation cancellation.' }
                default { '' }
            }
            $expectedOutcome = $_.Exception.Message -eq $expectedMessage
        }
        $expectedCalls = if ($mode -in @('Success', 'ElevationFailure')) { 1 } else { 0 }
        $checks += $expectedOutcome -and
            ($script:WorkerCalls - $before) -eq $expectedCalls -and
            -not (Test-Path -LiteralPath $script:DownloadDirectory)
    }
    return -not ($checks -contains $false)
}
Assert-Condition $elevationCleanupCheck 'Batch trust gating or download cleanup failed.'

Write-Host 'DotNetSteward verification passed.'
