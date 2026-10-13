function Find-DotNetSdk {
    <#
    .SYNOPSIS
    Finds official .NET SDK releases with Windows EXE installers.

    .DESCRIPTION
    Searches Microsoft's official .NET release metadata for SDK releases that
    provide Windows EXE installers. By default, returns the latest stable SDK
    in every release channel for the native Windows architecture.

    Use AllVersions to include every matching historical release.
    IncludePreview allows prerelease SDKs when searching by channel or feature
    band. An explicitly requested prerelease version does not require it.

    Prints an informational message and returns no data objects when no
    official Windows SDK releases match the requested filters.

    .PARAMETER Channel
    Limits results to one or more major/minor channels, such as 8.0 or 10.0.
    A major version such as 11 is shorthand for 11.0.

    .PARAMETER VersionBand
    Limits results to one or more SDK feature bands, such as 8.0.4xx.

    .PARAMETER Version
    Finds one or more exact SDK versions, including prerelease versions.

    .PARAMETER Architecture
    Selects x64, x86, or arm64 Windows installers. Defaults to the native
    Windows architecture.

    .PARAMETER IncludePreview
    Includes preview and release-candidate SDKs in channel or feature-band
    searches.

    .PARAMETER AllVersions
    Returns every matching release instead of only the latest in each channel
    or feature band.

    .EXAMPLE
    Find-DotNetSdk

    Finds the latest stable SDK in every official release channel.

    .EXAMPLE
    Find-DotNetSdk -Channel 8

    Finds the latest stable .NET 8 SDK for the native architecture.

    .EXAMPLE
    Find-DotNetSdk -VersionBand 8.0.4xx -AllVersions

    Lists every stable SDK in the 8.0.4xx feature band.

    .EXAMPLE
    Find-DotNetSdk -Version 11.0.100-preview.7

    Finds that exact prerelease SDK.
    #>

    [CmdletBinding(DefaultParameterSetName = 'Channel')]
    param(
        [Parameter(ParameterSetName = 'Channel')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Channel,

        [Parameter(Mandatory = $true, ParameterSetName = 'VersionBand')]
        [ValidateNotNullOrEmpty()]
        [string[]] $VersionBand,

        [Parameter(Mandatory = $true, ParameterSetName = 'Version')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Version,

        [ValidateNotNullOrEmpty()]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string[]] $Architecture,

        [switch] $IncludePreview,

        [switch] $AllVersions
    )

    Assert-DotNetStewardPlatform
    if ($PSBoundParameters.ContainsKey('Channel')) {
        $Channel = @(ConvertTo-DotNetChannels -Channels $Channel)
    }
    if ($PSCmdlet.ParameterSetName -eq 'VersionBand') {
        Assert-SdkFeatureBands -VersionBands $VersionBand
    }
    if ($PSCmdlet.ParameterSetName -eq 'Version') {
        Assert-ExactDotNetVersions -Versions $Version
    }
    if (-not $PSBoundParameters.ContainsKey('Architecture')) {
        $Architecture = @(Get-NativeDotNetArchitecture)
    }

    $originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            $originalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $releaseIndex = @(Get-ReleaseIndex)
        $releases = @(Get-AvailableSdkReleases -ReleaseIndex $releaseIndex `
            -Architectures $Architecture -Channels $Channel `
            -VersionBands $VersionBand -Versions $Version `
            -IncludePreview ([bool] $IncludePreview) `
            -AllVersions ([bool] $AllVersions))
        if ($releases.Count -eq 0) {
            Write-Host 'No official Windows .NET SDK releases matched the requested filters.'
            if ($PSCmdlet.ParameterSetName -ne 'Version' -and -not $IncludePreview) {
                Write-Host 'Use -IncludePreview to include preview and release-candidate releases.'
            }
            return
        }
        return $releases
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
    }
}
