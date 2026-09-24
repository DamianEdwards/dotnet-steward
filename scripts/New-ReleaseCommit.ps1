[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $BaseCommit,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-(?:pre|rc)\d+)?$')]
    [string] $Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ReleaseGit {
    param([string[]] $Arguments)

    $output = @(& git @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Release git command failed: git $($Arguments -join ' ')"
    }
    return $output
}

if ($Version -match '^0\.0\.0(?:-|$)') {
    throw 'Version 0.0.0 is reserved for development builds.'
}
$head = [string] (Invoke-ReleaseGit @('rev-parse', 'HEAD'))
if ($head -ne $BaseCommit) {
    throw "Release checkout '$head' does not match pinned main commit '$BaseCommit'."
}
if (@(Invoke-ReleaseGit @('status', '--porcelain', '--untracked-files=all')).Count -ne 0) {
    throw 'The release checkout must be clean before setting the version.'
}

$null = & (Join-Path $PSScriptRoot 'Set-ModuleVersion.ps1') `
    -ManifestPath '.\DotNetSteward.psd1' -Version $Version
$changes = @(Invoke-ReleaseGit @('status', '--porcelain', '--untracked-files=all'))
if ($changes.Count -ne 1 -or $changes[0] -cne ' M DotNetSteward.psd1') {
    throw 'The release commit must change only the module manifest version.'
}

$null = Invoke-ReleaseGit @('add', '--', 'DotNetSteward.psd1')
$null = Invoke-ReleaseGit @('commit', '--quiet', '-m', "Set module version to $Version")
$sourceCommit = [string] (Invoke-ReleaseGit @('rev-parse', 'HEAD'))
$parents = [string] (Invoke-ReleaseGit @('show', '-s', '--format=%P', 'HEAD'))
if ($parents -ne $BaseCommit) {
    throw 'The release commit must have the pinned main commit as its only parent.'
}
$committedFiles = @(Invoke-ReleaseGit @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'))
if ($committedFiles.Count -ne 1 -or $committedFiles[0] -cne 'DotNetSteward.psd1' -or
    @(Invoke-ReleaseGit @('status', '--porcelain', '--untracked-files=all')).Count -ne 0) {
    throw 'The release commit must contain only the manifest update and leave a clean checkout.'
}

[pscustomobject] @{
    BaseCommit = $BaseCommit
    SourceCommit = $sourceCommit
    Version = $Version
}
