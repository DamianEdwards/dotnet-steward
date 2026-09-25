function Uninstall-DotNetRuntime {
    <#
    .SYNOPSIS
    Uninstalls standalone .NET runtime Windows installer bundles.

    .DESCRIPTION
    Selects uninstallable standalone .NET Runtime, ASP.NET Core Runtime, and
    Windows Desktop Runtime bundles. Interactive selection starts empty.
    Uninstalling requires explicit confirmation unless -Force is supplied,
    including when -UninstallAll or -VersionBand is used. Shared MSI payloads
    and Visual Studio-managed runtimes are never uninstalled.

    .PARAMETER ProductType
    Limits selection to Runtime, AspNetCoreRuntime, or WindowsDesktopRuntime.

    .PARAMETER Architecture
    Limits selection to x64, x86, or arm64.

    .PARAMETER VersionBand
    Selects installed runtimes by major version, channel, or exact version.
    Disables interactive selection.

    .PARAMETER UninstallAll
    Selects all matching runtimes without interactive selection.

    .PARAMETER Force
    Skips the explicit uninstall confirmation (but not -Confirm).

    .EXAMPLE
    Uninstall-DotNetRuntime

    .EXAMPLE
    Uninstall-DotNetRuntime -ProductType WindowsDesktopRuntime -VersionBand 8.0

    .EXAMPLE
    Uninstall-DotNetRuntime -UninstallAll -Force
    #>
    [CmdletBinding(DefaultParameterSetName = 'Interactive',
        SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet('Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string[]] $ProductType = @(
            'Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime'
        ),

        [ValidateSet('x64', 'x86', 'arm64')]
        [string[]] $Architecture,

        [Parameter(Mandatory = $true, ParameterSetName = 'VersionBands')]
        [Alias('VersionBands', 'Version')]
        [ValidateNotNullOrEmpty()]
        [string[]] $VersionBand,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch] $UninstallAll,

        [switch] $Force
    )

    if ($env:OS -ne 'Windows_NT') {
        throw 'This command uninstalls runtimes registered by official Windows EXE installers and can only run on Windows.'
    }

    $installations = @(Get-DotNetInstallationInventory | Where-Object {
        $_.InstallerKind -eq 'Bundle' -and
            $_.ProductType -ne 'Sdk' -and
            $_.IsUninstallable -and
            $ProductType -contains $_.ProductType
    })
    if ($PSBoundParameters.ContainsKey('Architecture')) {
        $installations = @($installations | Where-Object {
            $Architecture -contains $_.Architecture
        })
    }
    if ($PSCmdlet.ParameterSetName -eq 'VersionBands') {
        $installations = @(Select-DotNetUninstallVersionBand `
            -Installations $installations -VersionBand $VersionBand)
    }

    Invoke-DotNetUninstallSelection -Installations $installations `
        -ParameterSetName $PSCmdlet.ParameterSetName -Force ([bool] $Force) -Cmdlet $PSCmdlet
}
