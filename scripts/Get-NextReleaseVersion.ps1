[CmdletBinding()]
param(
    [AllowEmptyCollection()]
    [string[]] $ExistingVersion = @(),

    [ValidatePattern('^\d+\.\d+\.\d+(?:-(?:pre|rc)\d+)?$')]
    [string] $InitialVersion = '0.1.0',

    [ValidateSet('auto', 'patch', 'minor', 'major')]
    [string] $VersionBump = 'auto',

    [ValidateSet('default', 'pre', 'rc', 'rtm')]
    [string] $Phase = 'default',

    [ValidateSet('patch', 'minor', 'major')]
    [string] $DefaultVersionBump = 'patch',

    [ValidateSet('pre', 'rc', 'rtm')]
    [string] $DefaultPhase = 'rtm'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ReleaseVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $normalized = $Text.Trim().TrimStart('v')
    if ($normalized -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<phase>pre|rc)(?<phaseNumber>\d+))?$') {
        throw "Unsupported release version '$Text'."
    }

    $phase = if ($Matches.ContainsKey('phase')) { $Matches.phase } else { 'rtm' }
    $phaseNumber = if ($Matches.ContainsKey('phaseNumber')) {
        [int] $Matches.phaseNumber
    }
    else {
        0
    }

    [pscustomobject] @{
        Version = $normalized
        Major = [int] $Matches.major
        Minor = [int] $Matches.minor
        Patch = [int] $Matches.patch
        BaseVersion = '{0}.{1}.{2}' -f $Matches.major, $Matches.minor, $Matches.patch
        Phase = $phase
        PhaseNumber = $phaseNumber
    }
}

function Compare-ReleaseVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Left,

        [Parameter(Mandatory = $true)]
        [object] $Right
    )

    foreach ($propertyName in @('Major', 'Minor', 'Patch')) {
        if ($Left.$propertyName -ne $Right.$propertyName) {
            return [math]::Sign($Left.$propertyName - $Right.$propertyName)
        }
    }

    $phaseOrder = @{
        pre = 0
        rc = 1
        rtm = 2
    }
    if ($phaseOrder[$Left.Phase] -ne $phaseOrder[$Right.Phase]) {
        return [math]::Sign($phaseOrder[$Left.Phase] - $phaseOrder[$Right.Phase])
    }

    return [math]::Sign($Left.PhaseNumber - $Right.PhaseNumber)
}

function Get-BumpedBaseVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Version,

        [Parameter(Mandatory = $true)]
        [ValidateSet('patch', 'minor', 'major')]
        [string] $Bump
    )

    switch ($Bump) {
        'major' { return '{0}.0.0' -f ($Version.Major + 1) }
        'minor' { return '{0}.{1}.0' -f $Version.Major, ($Version.Minor + 1) }
        'patch' { return '{0}.{1}.{2}' -f $Version.Major, $Version.Minor, ($Version.Patch + 1) }
    }
}

$targetPhase = if ($Phase -eq 'default') { $DefaultPhase } else { $Phase }
$appliedBump = 'none'
$versions = New-Object System.Collections.Generic.List[object]
foreach ($text in $ExistingVersion) {
    try {
        $versions.Add((ConvertTo-ReleaseVersion -Text $text))
    }
    catch {
        Write-Verbose "Ignoring non-release version '$text'."
    }
}

$latest = $null
foreach ($version in $versions) {
    if ($null -eq $latest -or
        (Compare-ReleaseVersion -Left $version -Right $latest) -gt 0) {
        $latest = $version
    }
}

if ($null -eq $latest) {
    $base = ConvertTo-ReleaseVersion -Text $InitialVersion
    if ($VersionBump -ne 'auto') {
        $base = ConvertTo-ReleaseVersion `
            -Text (Get-BumpedBaseVersion -Version $base -Bump $VersionBump)
        $appliedBump = $VersionBump
    }
    $baseVersion = $base.BaseVersion
    $phaseNumber = if ($targetPhase -eq 'rtm') { 0 } else { 1 }
}
elseif ($VersionBump -ne 'auto') {
    $baseVersion = Get-BumpedBaseVersion -Version $latest -Bump $VersionBump
    $appliedBump = $VersionBump
    $phaseNumber = if ($targetPhase -eq 'rtm') { 0 } else { 1 }
}
else {
    $phaseOrder = @{
        pre = 0
        rc = 1
        rtm = 2
    }
    $currentOrder = $phaseOrder[$latest.Phase]
    $targetOrder = $phaseOrder[$targetPhase]

    if ($targetPhase -eq $latest.Phase -and $targetPhase -ne 'rtm') {
        $baseVersion = $latest.BaseVersion
        $phaseNumber = $latest.PhaseNumber + 1
    }
    elseif ($targetOrder -gt $currentOrder) {
        $baseVersion = $latest.BaseVersion
        $phaseNumber = if ($targetPhase -eq 'rtm') { 0 } else { 1 }
    }
    else {
        $baseVersion = Get-BumpedBaseVersion -Version $latest -Bump $DefaultVersionBump
        $appliedBump = $DefaultVersionBump
        $phaseNumber = if ($targetPhase -eq 'rtm') { 0 } else { 1 }
    }
}

$prerelease = switch ($targetPhase) {
    'pre' { "pre$phaseNumber" }
    'rc' { "rc$phaseNumber" }
    'rtm' { '' }
}
$version = if ([string]::IsNullOrEmpty($prerelease)) {
    $baseVersion
}
else {
    "$baseVersion-$prerelease"
}

[pscustomobject] @{
    Version = $version
    BaseVersion = $baseVersion
    Prerelease = $prerelease
    Phase = $targetPhase
    PhaseNumber = $phaseNumber
    IsPrerelease = -not [string]::IsNullOrEmpty($prerelease)
    VersionBump = $appliedBump
}
