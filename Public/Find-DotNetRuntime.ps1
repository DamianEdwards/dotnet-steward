function Find-DotNetRuntime {
    <#
    .SYNOPSIS
    Finds official .NET runtime releases with Windows EXE installers.

    .DESCRIPTION
    Searches Microsoft's official release metadata for .NET Runtime, ASP.NET
    Core Runtime, and .NET Windows Desktop Runtime Windows EXE installers. By
    default, returns the latest stable release of each product in every channel
    for the native Windows architecture.

    Prints an informational message and returns no data objects when no
    official Windows runtime releases match the requested filters.

    .PARAMETER ProductType
    Limits results to Runtime, AspNetCoreRuntime, or WindowsDesktopRuntime.

    .PARAMETER Channel
    Limits results to one or more major/minor channels, such as 8.0 or 10.0.
    A major version such as 11 is shorthand for 11.0.

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
    Find-DotNetRuntime -ProductType AspNetCoreRuntime -Channel 11 -IncludePreview

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
        $Channel = @(ConvertTo-DotNetChannels -Channels $Channel)
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
        $releases = @(Get-AvailableRuntimeReleases -ReleaseIndex $releaseIndex `
            -ProductTypes $ProductType -Architectures $Architecture `
            -Channels $Channel -Versions $Version `
            -IncludePreview ([bool] $IncludePreview) `
            -AllVersions ([bool] $AllVersions))
        if ($releases.Count -eq 0) {
            Write-Host 'No official Windows .NET runtime releases matched the requested filters.'
            if ($PSCmdlet.ParameterSetName -eq 'Channel' -and -not $IncludePreview) {
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
