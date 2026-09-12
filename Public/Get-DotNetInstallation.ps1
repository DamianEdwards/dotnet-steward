function Get-DotNetInstallation {
    <#
    .SYNOPSIS
    Lists .NET SDK and runtime installations registered with Windows Installer.

    .DESCRIPTION
    Returns logical installations for .NET SDKs, .NET runtimes, ASP.NET Core
    runtimes, and .NET Windows Desktop runtimes across x64, x86, and Arm64.
    Standalone EXE bundles are actionable. MSI payloads owned by an SDK, Visual
    Studio, or another installer are returned as read-only records with their
    ownership and management source.

    .PARAMETER ProductType
    Limits results to one or more .NET product types.

    .PARAMETER Architecture
    Limits results to x64, x86, or arm64 payload architectures.

    .PARAMETER ManagementSource
    Limits results by the installer or product that manages them.

    .EXAMPLE
    Get-DotNetInstallation

    Lists all installer-registered .NET SDKs and runtime payloads.

    .EXAMPLE
    Get-DotNetInstallation -ProductType Runtime, AspNetCoreRuntime

    Lists .NET and ASP.NET Core runtime installations.

    .EXAMPLE
    Get-DotNetInstallation | Where-Object ManagedByVisualStudio

    Lists read-only components managed by Visual Studio.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Sdk', 'Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string[]] $ProductType,

        [ValidateSet('x64', 'x86', 'arm64')]
        [string[]] $Architecture,

        [ValidateSet(
            'Standalone',
            'VisualStudio',
            'StandaloneAndVisualStudio',
            'SharedInstaller',
            'WindowsInstaller'
        )]
        [string[]] $ManagementSource
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Get-DotNetInstallation supports Windows installer-managed .NET installations only.'
    }

    $installations = @(Get-DotNetInstallationInventory)
    if ($PSBoundParameters.ContainsKey('ProductType')) {
        $installations = @($installations | Where-Object {
            $ProductType -contains $_.ProductType
        })
    }
    if ($PSBoundParameters.ContainsKey('Architecture')) {
        $installations = @($installations | Where-Object {
            $Architecture -contains $_.Architecture
        })
    }
    if ($PSBoundParameters.ContainsKey('ManagementSource')) {
        $installations = @($installations | Where-Object {
            $ManagementSource -contains $_.ManagementSource
        })
    }

    return Sort-DotNetInstallations -Installations $installations
}
