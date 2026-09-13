[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ManifestPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-(?:pre|rc)\d+)?$')]
    [string] $Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$match = [regex]::Match(
    $Version,
    '^(?<base>\d+\.\d+\.\d+)(?:-(?<prerelease>(?:pre|rc)\d+))?$'
)
$baseVersion = $match.Groups['base'].Value
$prerelease = $match.Groups['prerelease'].Value
$resolvedPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$content = [IO.File]::ReadAllText($resolvedPath)
$newLine = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }

$moduleVersionPattern = "(?m)^(\s*ModuleVersion\s*=\s*)'[^']*'"
if (-not [regex]::IsMatch($content, $moduleVersionPattern)) {
    throw "Manifest '$resolvedPath' does not contain a ModuleVersion assignment."
}
$content = [regex]::Replace(
    $content,
    $moduleVersionPattern,
    "`${1}'$baseVersion'",
    1
)

$prereleasePattern = "(?m)^(?<indent>[^\S\r\n]*)Prerelease[^\S\r\n]*=[^\S\r\n]*'[^']*'[^\S\r\n]*(?<newline>\r?\n)?"
if ([string]::IsNullOrEmpty($prerelease)) {
    $content = [regex]::Replace($content, $prereleasePattern, '', 1)
}
elseif ([regex]::IsMatch($content, $prereleasePattern)) {
    $prereleaseMatch = [regex]::Match($content, $prereleasePattern)
    $replacement = $prereleaseMatch.Groups['indent'].Value +
        "Prerelease = '$prerelease'" +
        $prereleaseMatch.Groups['newline'].Value
    $content = $content.Substring(0, $prereleaseMatch.Index) +
        $replacement +
        $content.Substring($prereleaseMatch.Index + $prereleaseMatch.Length)
}
else {
    $psDataPattern = '(?m)^(?<indent>[^\S\r\n]*)PSData[^\S\r\n]*=[^\S\r\n]*@\{[^\S\r\n]*(?<newline>\r?\n)'
    $psDataMatch = [regex]::Match($content, $psDataPattern)
    if (-not $psDataMatch.Success) {
        throw "Manifest '$resolvedPath' does not contain a PSData block."
    }

    $indent = $psDataMatch.Groups['indent'].Value + '    '
    $replacement = $psDataMatch.Value +
        $indent + "Prerelease = '$prerelease'" + $psDataMatch.Groups['newline'].Value
    $content = $content.Substring(0, $psDataMatch.Index) +
        $replacement +
        $content.Substring($psDataMatch.Index + $psDataMatch.Length)
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($resolvedPath, $content, $utf8NoBom)
$manifest = Test-ModuleManifest -Path $resolvedPath

[pscustomobject] @{
    Path = $resolvedPath
    Version = $Version
    ModuleVersion = [string] $manifest.Version
    Prerelease = $prerelease
}
