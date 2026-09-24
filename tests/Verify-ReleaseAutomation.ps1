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
$releaseSourceScript = Join-Path $repositoryRoot 'scripts\Test-ReleaseSource.ps1'
$releaseCommitScript = Join-Path $repositoryRoot 'scripts\New-ReleaseCommit.ps1'

$bootstrapVersion = & $versionScript
Assert-ReleaseCondition ($bootstrapVersion.Version -eq '0.1.0') `
    'A repository without release history must bootstrap independently of the development manifest.'
$releaseMinor = & $versionScript -ExistingVersion 'v0.1.0' -VersionBump minor -Phase rtm
Assert-ReleaseCondition ($releaseMinor.Version -eq '0.2.0') `
    'A minor release must use release history rather than the development manifest.'

& {
    $source = '0123456789abcdef0123456789abcdef01234567'
    $run = [pscustomobject] @{
        id = 123
        head_sha = $source
        head_branch = 'main'
        event = 'push'
        status = 'completed'
        conclusion = 'success'
        run_attempt = 2
    }
    $gate = [pscustomobject] @{
        name = 'Verification'
        head_sha = $source
        status = 'completed'
        conclusion = 'success'
    }
    $runs = @($run)
    $gates = @($gate)
    $failure = ''
    $requests = New-Object System.Collections.Generic.List[string]
    function gh {
        param($Command, $Endpoint)

        if ($Command -ne 'api') { throw "Unexpected gh command '$Command'." }
        $requests.Add($Endpoint)
        Set-Variable -Name LASTEXITCODE -Value 0 -Scope 1
        if ($Endpoint -like '*workflows/verify.yml/runs?*') {
            if ($failure -eq 'runs') {
                Set-Variable -Name LASTEXITCODE -Value 1 -Scope 1
                return
            }
            return ConvertTo-Json -InputObject @{ workflow_runs = $runs } -Depth 5
        }
        if ($Endpoint -eq 'repos/example/repo/actions/runs/123/attempts/2/jobs?per_page=100') {
            if ($failure -eq 'jobs') {
                Set-Variable -Name LASTEXITCODE -Value 1 -Scope 1
                return
            }
            return ConvertTo-Json -InputObject @{ jobs = $gates } -Depth 5
        }
        throw "Unexpected verification endpoint '$Endpoint'."
    }
    function Assert-SourceRejected {
        param([string] $ExpectedMessage)

        $message = ''
        try {
            $null = & $releaseSourceScript -Repository 'example/repo' -SourceCommit $source
        }
        catch {
            $message = $_.Exception.Message
        }
        Assert-ReleaseCondition ($message -like "*$ExpectedMessage*") `
            "Expected release-source rejection containing '$ExpectedMessage', got '$message'."
    }

    $verified = & $releaseSourceScript -Repository 'example/repo' -SourceCommit $source
    Assert-ReleaseCondition ($verified.SourceCommit -eq $source -and
        $verified.VerificationRunId -eq 123 -and $requests.Count -eq 2 -and
        $requests[0].Contains("head_sha=$source&branch=main")) `
        'Release verification was not bound to the pinned main commit and latest run attempt.'
    $runs = @()
    Assert-SourceRejected 'No Verify workflow run'
    $wrongSourceRun = $run.PSObject.Copy()
    $wrongSourceRun.head_sha = ('f' * 40)
    $runs = @($wrongSourceRun)
    Assert-SourceRejected 'No Verify workflow run'
    $pullRequestRun = $run.PSObject.Copy()
    $pullRequestRun.event = 'pull_request'
    $runs = @($pullRequestRun)
    Assert-SourceRejected 'No Verify workflow run'
    $failedRun = $run.PSObject.Copy()
    $failedRun.id = 124
    $failedRun.conclusion = 'failure'
    $runs = @($run, $failedRun)
    Assert-SourceRejected 'has not succeeded'
    $failedRun.status = 'in_progress'
    $failedRun.conclusion = $null
    Assert-SourceRejected 'has not succeeded'
    $runs = @($run)
    $gates = @()
    Assert-SourceRejected 'does not have a successful Verification gate'
    $wrongGate = $gate.PSObject.Copy()
    $wrongGate.head_sha = ('f' * 40)
    $gates = @($wrongGate)
    Assert-SourceRejected 'does not have a successful Verification gate'
    $wrongGate.head_sha = $source
    $wrongGate.conclusion = 'failure'
    Assert-SourceRejected 'does not have a successful Verification gate'
    $gates = @($gate)
    $failure = 'runs'
    Assert-SourceRejected 'Could not read verification runs'
    $failure = 'jobs'
    Assert-SourceRejected 'Could not read the verification gate'
}

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
    $gitPackage = & $packageScript -SourcePath $repositoryRoot `
        -DestinationPath (Join-Path $temporaryRoot 'source')
    $remotePath = Join-Path $temporaryRoot 'remote.git'
    Push-Location $gitPackage.ModulePath
    try {
        function Invoke-TestGit {
            param([string[]] $Arguments)

            $output = @(& git @Arguments)
            if ($LASTEXITCODE -ne 0) {
                throw "Release regression git command failed: git $($Arguments -join ' ')"
            }
            return $output
        }

        $null = Invoke-TestGit @('init', '--quiet', '--initial-branch=main')
        $null = Invoke-TestGit @('config', 'user.name', 'Release test')
        $null = Invoke-TestGit @('config', 'user.email', 'release-test@example.invalid')
        $null = Invoke-TestGit @('config', 'commit.gpgsign', 'false')
        $null = Invoke-TestGit @('config', 'tag.gpgsign', 'false')
        $null = Invoke-TestGit @('config', 'core.autocrlf', 'false')
        $null = & $setVersionScript -ManifestPath '.\DotNetSteward.psd1' -Version '0.0.0'
        $null = Invoke-TestGit @('add', '--', '.')
        $null = Invoke-TestGit @('commit', '--quiet', '-m', 'Development source')
        $baseCommit = [string] (Invoke-TestGit @('rev-parse', 'HEAD'))
        $null = Invoke-TestGit @('init', '--quiet', '--bare', $remotePath)
        $null = Invoke-TestGit @('remote', 'add', 'origin', $remotePath)
        $null = Invoke-TestGit @('push', '--quiet', 'origin', 'refs/heads/main:refs/heads/main')
        $null = Invoke-TestGit @('checkout', '--quiet', '--detach', $baseCommit)

        $badBaseRejected = $false
        try {
            $null = & $releaseCommitScript -BaseCommit ('f' * 40) -Version '0.2.0'
        }
        catch { $badBaseRejected = $_.Exception.Message -like '*does not match pinned main commit*' }
        Assert-ReleaseCondition $badBaseRejected 'A release commit accepted the wrong base.'

        $developmentVersionRejected = $false
        try {
            $null = & $releaseCommitScript -BaseCommit $baseCommit -Version '0.0.0'
        }
        catch { $developmentVersionRejected = $_.Exception.Message -like '*reserved for development*' }
        Assert-ReleaseCondition $developmentVersionRejected 'The development sentinel could be released.'

        $dirtyFile = Join-Path $gitPackage.ModulePath 'unexpected.txt'
        [IO.File]::WriteAllText($dirtyFile, 'Unrelated change')
        $dirtySourceRejected = $false
        try {
            $null = & $releaseCommitScript -BaseCommit $baseCommit -Version '0.2.0'
        }
        catch { $dirtySourceRejected = $_.Exception.Message -like '*must be clean*' }
        Assert-ReleaseCondition $dirtySourceRejected 'A release commit accepted unrelated changes.'
        Remove-Item -LiteralPath $dirtyFile

        $releaseCommit = & $releaseCommitScript -BaseCommit $baseCommit -Version '0.2.0'
        $changedFiles = @(Invoke-TestGit @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'))
        $parent = [string] (Invoke-TestGit @('show', '-s', '--format=%P', 'HEAD'))
        $releaseManifest = Import-PowerShellDataFile '.\DotNetSteward.psd1'
        Assert-ReleaseCondition ($releaseCommit.BaseCommit -eq $baseCommit -and
            $releaseCommit.SourceCommit -ne $baseCommit -and $parent -eq $baseCommit -and
            $changedFiles.Count -eq 1 -and $changedFiles[0] -eq 'DotNetSteward.psd1' -and
            $releaseManifest.ModuleVersion -eq '0.2.0' -and
            @(Invoke-TestGit @('status', '--porcelain')).Count -eq 0) `
            'The release-only commit did not preserve its base and version-only change.'

        $null = Invoke-TestGit @('tag', '-a', 'v0.2.0', $releaseCommit.SourceCommit, '-m', 'Release v0.2.0')
        $null = Invoke-TestGit @('-c', 'push.followTags=false', 'push', '--quiet', 'origin',
            'refs/tags/v0.2.0:refs/tags/v0.2.0')
        $remoteMain = [string] (Invoke-TestGit @('--git-dir', $remotePath, 'rev-parse', 'refs/heads/main'))
        $remoteRelease = [string] (Invoke-TestGit @('--git-dir', $remotePath, 'rev-parse', 'refs/tags/v0.2.0^{}'))
        $mainManifest = (Invoke-TestGit @('--git-dir', $remotePath, 'show', 'main:DotNetSteward.psd1')) -join "`n"
        Assert-ReleaseCondition ($remoteMain -eq $baseCommit -and
            $remoteRelease -eq $releaseCommit.SourceCommit -and
            $mainManifest -match "ModuleVersion = '0.0.0'") `
            'Publishing a release tag changed main or tagged the wrong commit.'
    }
    finally {
        Pop-Location
    }

    $package = & $packageScript -SourcePath $repositoryRoot `
        -DestinationPath (Join-Path $temporaryRoot 'package')
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
