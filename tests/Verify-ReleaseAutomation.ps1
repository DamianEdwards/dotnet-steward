[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ReleaseCondition {
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
$versionScript = Join-Path $repositoryRoot 'scripts\Get-NextReleaseVersion.ps1'
$setVersionScript = Join-Path $repositoryRoot 'scripts\Set-ModuleVersion.ps1'
$packageScript = Join-Path $repositoryRoot 'scripts\New-ModulePackage.ps1'
$releaseAssetsScript = Join-Path $repositoryRoot 'scripts\New-ReleaseAssets.ps1'
$testReleaseAssetsScript = Join-Path $repositoryRoot 'scripts\Test-ReleaseAssets.ps1'

$firstStable = & $versionScript -InitialVersion '0.1.0'
Assert-ReleaseCondition ($firstStable.Version -eq '0.1.0') `
    'The initial stable version was not preserved.'

$nextPatch = & $versionScript -ExistingVersion '0.1.0'
Assert-ReleaseCondition ($nextPatch.Version -eq '0.1.1') `
    'The default patch release was not calculated.'

$firstPreview = & $versionScript -ExistingVersion '0.1.0' -Phase pre
Assert-ReleaseCondition ($firstPreview.Version -eq '0.1.1-pre1') `
    'The first preview version was not calculated.'

$nextPreview = & $versionScript -ExistingVersion '0.1.1-pre1' -Phase pre
Assert-ReleaseCondition ($nextPreview.Version -eq '0.1.1-pre2') `
    'The preview phase number was not incremented.'

$firstReleaseCandidate = & $versionScript `
    -ExistingVersion '0.1.1-pre1', '0.1.1-pre2' -Phase rc
Assert-ReleaseCondition ($firstReleaseCandidate.Version -eq '0.1.1-rc1') `
    'The preview was not promoted to the first release candidate.'

$stablePromotion = & $versionScript `
    -ExistingVersion '0.1.1-pre2', '0.1.1-rc1' -Phase rtm
Assert-ReleaseCondition ($stablePromotion.Version -eq '0.1.1') `
    'The release candidate was not promoted to stable.'

$prereleaseManifestProgression = & $versionScript `
    -ExistingVersion '0.1.0-pre1' `
    -InitialVersion '0.1.0-pre1' `
    -Phase rc
Assert-ReleaseCondition ($prereleaseManifestProgression.Version -eq '0.1.0-rc1') `
    'A prerelease-valued source manifest blocked phase progression.'

$nextMinor = & $versionScript -ExistingVersion '1.2.3' `
    -DefaultVersionBump minor
Assert-ReleaseCondition ($nextMinor.Version -eq '1.3.0') `
    'The configurable default minor bump was not applied.'

$explicitMajorPreview = & $versionScript -ExistingVersion '1.2.3' `
    -VersionBump major -Phase pre
Assert-ReleaseCondition ($explicitMajorPreview.Version -eq '2.0.0-pre1') `
    'The explicit major preview bump was not applied.'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'dotnet-steward-release-test-{0}' -f [guid]::NewGuid().ToString('N')
)
try {
    $package = & $packageScript -SourcePath $repositoryRoot `
        -DestinationPath $temporaryRoot
    $sourceManifestHash = (Get-FileHash `
        -LiteralPath (Join-Path $repositoryRoot 'DotNetSteward.psd1') `
        -Algorithm SHA256).Hash

    $null = & $setVersionScript -ManifestPath $package.ManifestPath `
        -Version '2.0.0-rc1'
    $prereleaseManifest = Import-PowerShellDataFile -LiteralPath $package.ManifestPath
    Assert-ReleaseCondition ($prereleaseManifest.ModuleVersion -eq '2.0.0') `
        'The package base module version was not updated.'
    Assert-ReleaseCondition (
        $prereleaseManifest.PrivateData.PSData.Prerelease -eq 'rc1'
    ) 'The package prerelease label was not updated.'

    if ($null -ne (Get-Command Compress-PSResource -ErrorAction SilentlyContinue)) {
        $prereleaseOutput = Join-Path $temporaryRoot 'prerelease'
        $sourceCommit = '0123456789abcdef0123456789abcdef01234567'
        $prereleaseAssets = & $releaseAssetsScript `
            -ModulePath $package.ModulePath `
            -OutputPath $prereleaseOutput `
            -Version '2.0.0-rc1' `
            -SourceCommit $sourceCommit `
            -Signed $false
        $verifiedPrerelease = & $testReleaseAssetsScript `
            -Path $prereleaseOutput `
            -Version '2.0.0-rc1' `
            -SourceCommit $sourceCommit
        Assert-ReleaseCondition (
            (Split-Path -Leaf $prereleaseAssets.NupkgPath) -eq
                'DotNetSteward.2.0.0-rc1.nupkg' -and
            $verifiedPrerelease.Version -eq '2.0.0-rc1'
        ) 'The prerelease NuGet package version was not generated correctly.'
    }

    $null = & $setVersionScript -ManifestPath $package.ManifestPath `
        -Version '2.0.0'
    $stableManifest = Import-PowerShellDataFile -LiteralPath $package.ManifestPath
    Assert-ReleaseCondition (
        -not $stableManifest.PrivateData.PSData.ContainsKey('Prerelease')
    ) 'The prerelease label was not removed for a stable package.'
    $stableManifestText = [IO.File]::ReadAllText($package.ManifestPath)
    Assert-ReleaseCondition (-not $stableManifestText.Contains("`r`r")) `
        'Manifest version changes introduced duplicate carriage returns.'
    if ($stableManifestText.Contains("`r`n")) {
        Assert-ReleaseCondition (
            -not [regex]::IsMatch($stableManifestText, '(?<!\r)\n')
        ) 'Manifest version changes introduced mixed line endings.'
    }
    Assert-ReleaseCondition (
        [regex]::IsMatch($stableManifestText, '(?m)^            Tags\s*=')
    ) 'Manifest version changes corrupted PSData indentation.'

    $updatedSourceManifestHash = (Get-FileHash `
        -LiteralPath (Join-Path $repositoryRoot 'DotNetSteward.psd1') `
        -Algorithm SHA256).Hash
    Assert-ReleaseCondition ($sourceManifestHash -eq $updatedSourceManifestHash) `
        'Package version tests modified the source manifest.'

    Remove-Module DotNetSteward -Force -ErrorAction SilentlyContinue
    Import-Module $package.ManifestPath -Force
    Assert-ReleaseCondition ($null -ne (Get-Module DotNetSteward)) `
        'The staged module package could not be imported.'

    if ($null -ne (Get-Command Compress-PSResource -ErrorAction SilentlyContinue)) {
        $releaseOutput = Join-Path $temporaryRoot 'release'
        $assets = & $releaseAssetsScript -ModulePath $package.ModulePath `
            -OutputPath $releaseOutput -Version '2.0.0' `
            -SourceCommit $sourceCommit -Signed $false
        $verifiedAssets = & $testReleaseAssetsScript -Path $releaseOutput `
            -Version '2.0.0' -SourceCommit $sourceCommit
        Assert-ReleaseCondition (
            (Test-Path -LiteralPath $assets.NupkgPath -PathType Leaf) -and
            (Test-Path -LiteralPath $assets.ZipPath -PathType Leaf) -and
            $verifiedAssets.Version -eq '2.0.0' -and
            -not $verifiedAssets.Signed
        ) 'Release assets were not created and verified correctly.'

        $expandedZip = Join-Path $temporaryRoot 'expanded-zip'
        Expand-Archive -LiteralPath $assets.ZipPath -DestinationPath $expandedZip
        Assert-ReleaseCondition (
            Test-Path -LiteralPath (
                Join-Path $expandedZip 'DotNetSteward\DotNetSteward.psd1'
            ) -PathType Leaf
        ) 'The ZIP package does not contain a DotNetSteward module directory.'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $nupkgArchive = [IO.Compression.ZipFile]::OpenRead($assets.NupkgPath)
        try {
            $nupkgEntries = @($nupkgArchive.Entries | ForEach-Object FullName)
            Assert-ReleaseCondition ($nupkgEntries -contains 'DotNetSteward.psd1') `
                'The NuGet package does not contain the module manifest at its root.'
        }
        finally {
            $nupkgArchive.Dispose()
        }
    }
    elseif ($env:DOTNET_STEWARD_REQUIRE_PACKAGING_TESTS -eq 'true') {
        throw 'Compress-PSResource is required for release asset verification.'
    }
    else {
        Write-Warning 'Compress-PSResource is unavailable; release asset checks were skipped.'
    }
}
finally {
    Remove-Module DotNetSteward -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host 'Release automation checks passed.'
