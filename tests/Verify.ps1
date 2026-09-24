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

Write-Host 'DotNetSteward verification passed.'
