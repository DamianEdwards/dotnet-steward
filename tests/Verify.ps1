[CmdletBinding()]
param(
    [switch] $SkipOnlineChecks
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
$manifestPath = Join-Path $repositoryRoot 'DotNetSteward.psd1'
$modulePath = Join-Path $repositoryRoot 'DotNetSteward.psm1'

Write-Host 'Checking PowerShell syntax...'
$powerShellFiles = @(
    Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File |
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

Write-Host 'Checking the module manifest and exports...'
$manifest = Test-ModuleManifest -Path $manifestPath
Assert-Condition ($manifest.RootModule -eq 'DotNetSteward.psm1') `
    'The manifest does not reference DotNetSteward.psm1.'

Remove-Module DotNetSteward -Force -ErrorAction SilentlyContinue
Import-Module $manifestPath -Force
$module = Get-Module DotNetSteward
Assert-Condition ($null -ne $module) 'DotNetSteward did not import.'

$expectedExports = @(
    'Get-DotNetInstallation'
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
