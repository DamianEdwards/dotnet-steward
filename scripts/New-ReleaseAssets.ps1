[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ModulePath,

    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-(?:pre|rc)\d+)?$')]
    [string] $Version,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $SourceCommit,

    [Parameter(Mandatory = $true)]
    [bool] $Signed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
if ((Split-Path -Leaf $resolvedModulePath) -cne 'DotNetSteward') {
    throw "The package directory must be named 'DotNetSteward'."
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Release output already exists: '$OutputPath'."
}
[void] (New-Item -Path $OutputPath -ItemType Directory -Force)
$resolvedOutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

$compressCommand = Get-Command Compress-PSResource -ErrorAction SilentlyContinue
if ($null -eq $compressCommand) {
    throw 'Compress-PSResource 1.1.0 or later is required to create release assets.'
}

$manifestPath = Join-Path $resolvedModulePath 'DotNetSteward.psd1'
$manifestData = Import-PowerShellDataFile -LiteralPath $manifestPath
$manifestVersion = [string] $manifestData.ModuleVersion
if ($manifestData.PrivateData.PSData.ContainsKey('Prerelease') -and
    -not [string]::IsNullOrWhiteSpace(
        [string] $manifestData.PrivateData.PSData.Prerelease
    )) {
    $manifestVersion += "-$($manifestData.PrivateData.PSData.Prerelease)"
}
if ($manifestVersion -ne $Version) {
    throw "Package manifest version '$manifestVersion' does not match release version '$Version'."
}

$nupkg = Compress-PSResource -Path $resolvedModulePath `
    -DestinationPath $resolvedOutputPath -PassThru
$nupkgPath = $nupkg.FullName
if (-not (Test-Path -LiteralPath $nupkgPath -PathType Leaf)) {
    throw 'Compress-PSResource did not create a NuGet package.'
}

$zipPath = Join-Path $resolvedOutputPath "DotNetSteward-$Version.zip"
Compress-Archive -Path $resolvedModulePath -DestinationPath $zipPath `
    -CompressionLevel Optimal

$artifacts = @(
    Get-Item -LiteralPath $nupkgPath
    Get-Item -LiteralPath $zipPath
)
$artifactRecords = @($artifacts | Sort-Object Name | ForEach-Object {
    [pscustomobject] @{
        name = $_.Name
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})

$checksumPath = Join-Path $resolvedOutputPath 'checksums.txt'
$checksumLines = @($artifactRecords | ForEach-Object {
    '{0}  {1}' -f $_.sha256, $_.name
})
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText(
    $checksumPath,
    ($checksumLines -join "`n") + "`n",
    $utf8NoBom
)

$metadataPath = Join-Path $resolvedOutputPath 'release-metadata.json'
$metadata = [ordered] @{
    schemaVersion = 1
    version = $Version
    sourceCommit = $SourceCommit.ToLowerInvariant()
    signed = $Signed
    artifacts = $artifactRecords
}
[IO.File]::WriteAllText(
    $metadataPath,
    ($metadata | ConvertTo-Json -Depth 5) + "`n",
    $utf8NoBom
)

[pscustomobject] @{
    ModulePath = $resolvedModulePath
    NupkgPath = $nupkgPath
    ZipPath = $zipPath
    ChecksumsPath = $checksumPath
    MetadataPath = $metadataPath
}
