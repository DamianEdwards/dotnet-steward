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

    Checks Microsoft's official release metadata for support status, using the
    lifecycle and patch-status categories shown by dotnet sdk check. If metadata
    cannot be retrieved, returns the local inventory with Unknown status and a
    warning. Installer ownership and updateability are not changed.

    .PARAMETER ProductType
    Limits results to one or more .NET product types.

    .PARAMETER Architecture
    Limits results to x64, x86, or arm64 payload architectures.

    .PARAMETER ManagementSource
    Limits results by the installer or product that manages them.

    .PARAMETER SkipSupportCheck
    Skips online release metadata lookups and reports Not checked support status.

    .EXAMPLE
    Get-DotNetInstallation

    Lists all installer-registered .NET SDKs and runtime payloads.

    .EXAMPLE
    Get-DotNetInstallation -ProductType Runtime, AspNetCoreRuntime

    Lists .NET and ASP.NET Core runtime installations.

    .EXAMPLE
    Get-DotNetInstallation | Where-Object ManagedByVisualStudio

    Lists read-only components managed by Visual Studio.

    .EXAMPLE
    Get-DotNetInstallation -SkipSupportCheck

    Lists local installations without accessing the online release catalog.
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
        [string[]] $ManagementSource,

        [switch] $SkipSupportCheck
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

    Add-InstallationSupportStatus -Installations $installations -SkipSupportCheck:$SkipSupportCheck
    return Sort-DotNetInstallations -Installations $installations
}
