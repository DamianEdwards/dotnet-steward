[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $SourcePath,

    [Parameter(Mandatory = $true)]
    [string] $DestinationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = (Resolve-Path -LiteralPath $SourcePath).Path
if (Test-Path -LiteralPath $DestinationPath) {
    throw "Package destination already exists: '$DestinationPath'."
}

$modulePath = Join-Path $DestinationPath 'DotNetSteward'
[void] (New-Item -Path $modulePath -ItemType Directory -Force)

foreach ($fileName in @(
    'DotNetSteward.Format.ps1xml',
    'DotNetSteward.psd1',
    'DotNetSteward.psm1',
    'LICENSE',
    'README.md'
)) {
    $sourceFile = Join-Path $sourceRoot $fileName
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required package file is missing: '$sourceFile'."
    }
    Copy-Item -LiteralPath $sourceFile -Destination $modulePath
}

foreach ($directoryName in @('Private', 'Public')) {
    $sourceDirectory = Join-Path $sourceRoot $directoryName
    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw "Required package directory is missing: '$sourceDirectory'."
    }
    Copy-Item -LiteralPath $sourceDirectory -Destination $modulePath -Recurse
}

$manifestPath = Join-Path $modulePath 'DotNetSteward.psd1'
$manifest = Test-ModuleManifest -Path $manifestPath

[pscustomobject] @{
    ModulePath = $modulePath
    ManifestPath = $manifestPath
    Version = [string] $manifest.Version
}
