[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $Path,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-(?:pre|rc)\d+)?$')]
    [string] $Version,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $SourceCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$metadataPath = Join-Path $resolvedPath 'release-metadata.json'
$checksumsPath = Join-Path $resolvedPath 'checksums.txt'
foreach ($requiredPath in @($metadataPath, $checksumsPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required release file is missing: '$requiredPath'."
    }
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($metadata.schemaVersion -ne 1) {
    throw "Unsupported release metadata schema '$($metadata.schemaVersion)'."
}
if ($metadata.version -ne $Version) {
    throw "Release metadata version '$($metadata.version)' does not match '$Version'."
}
if ($metadata.sourceCommit -ne $SourceCommit.ToLowerInvariant()) {
    throw "Release metadata source commit '$($metadata.sourceCommit)' does not match '$SourceCommit'."
}

$expectedArtifacts = @($metadata.artifacts | Sort-Object name)
if ($expectedArtifacts.Count -eq 0) {
    throw 'Release metadata contains no artifacts.'
}
$checksumEntries = @{}
foreach ($line in Get-Content -LiteralPath $checksumsPath) {
    if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})\s{2}(?<name>.+)$') {
        throw "Invalid checksum line: '$line'."
    }
    $checksumEntries[$Matches.name] = $Matches.hash.ToLowerInvariant()
}

foreach ($artifact in $expectedArtifacts) {
    $artifactPath = Join-Path $resolvedPath $artifact.name
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Release artifact is missing: '$($artifact.name)'."
    }
    if (-not $checksumEntries.ContainsKey([string] $artifact.name)) {
        throw "Checksums do not contain '$($artifact.name)'."
    }

    $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string] $artifact.sha256).ToLowerInvariant()
    if ($actualHash -ne $expectedHash -or
        $actualHash -ne $checksumEntries[[string] $artifact.name]) {
        throw "SHA-256 validation failed for '$($artifact.name)'."
    }
}

if ($checksumEntries.Count -ne $expectedArtifacts.Count) {
    throw 'Release metadata and checksum artifact inventories differ.'
}

$nupkgName = "DotNetSteward.$Version.nupkg"
$zipName = "DotNetSteward-$Version.zip"
if (-not $checksumEntries.ContainsKey($nupkgName) -or
    -not $checksumEntries.ContainsKey($zipName)) {
    throw 'Release assets do not contain the expected NuGet package and ZIP archive.'
}

[pscustomobject] @{
    Version = [string] $metadata.version
    SourceCommit = [string] $metadata.sourceCommit
    Signed = [bool] $metadata.signed
    NupkgPath = Join-Path $resolvedPath $nupkgName
    ZipPath = Join-Path $resolvedPath $zipName
}
