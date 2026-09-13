function Find-DotNetRuntime {
    <#
    .SYNOPSIS
    Finds official .NET runtime releases with Windows EXE installers.

    .DESCRIPTION
    Searches Microsoft's official release metadata for .NET Runtime, ASP.NET
    Core Runtime, and .NET Windows Desktop Runtime Windows EXE installers. By
    default, returns the latest stable release of each product in every channel
    for the native Windows architecture.

    .PARAMETER ProductType
    Limits results to Runtime, AspNetCoreRuntime, or WindowsDesktopRuntime.

    .PARAMETER Channel
    Limits results to one or more major/minor channels, such as 8.0 or 10.0.

    .PARAMETER Version
    Finds one or more exact runtime versions, including prerelease versions.

    .PARAMETER Architecture
    Selects x64, x86, or arm64 Windows installers. Defaults to the native
    Windows architecture.

    .PARAMETER IncludePreview
    Includes preview and release-candidate runtimes in channel searches.

    .PARAMETER AllVersions
    Returns every matching release instead of only the latest in each channel.

    .EXAMPLE
    Find-DotNetRuntime

    Finds the latest stable release of every runtime product in every channel.

    .EXAMPLE
    Find-DotNetRuntime -ProductType WindowsDesktopRuntime -Channel 8.0

    Finds the latest stable .NET 8 Windows Desktop Runtime.

    .EXAMPLE
    Find-DotNetRuntime -ProductType AspNetCoreRuntime -Channel 11.0 -IncludePreview

    Finds the latest ASP.NET Core Runtime in the .NET 11 channel, including
    prereleases.
    #>

    [CmdletBinding(DefaultParameterSetName = 'Channel')]
    param(
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string[]] $ProductType = @(
            'Runtime',
            'AspNetCoreRuntime',
            'WindowsDesktopRuntime'
        ),

        [Parameter(ParameterSetName = 'Channel')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Channel,

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
        Assert-DotNetChannels -Channels $Channel
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
        return Get-AvailableRuntimeReleases -ReleaseIndex $releaseIndex `
            -ProductTypes $ProductType -Architectures $Architecture `
            -Channels $Channel -Versions $Version `
            -IncludePreview ([bool] $IncludePreview) `
            -AllVersions ([bool] $AllVersions)
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
    }
}
