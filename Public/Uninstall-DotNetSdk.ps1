function Uninstall-DotNetSdk {
    <#
    .SYNOPSIS
    Uninstalls standalone .NET SDK Windows installer bundles.

    .DESCRIPTION
    Selects uninstallable standalone SDK bundles. The default interactive
    checklist starts with no installations selected. Even with -UninstallAll
    or -VersionBand, uninstalling requires explicit confirmation unless -Force
    is supplied. Shared MSI payloads and Visual Studio-managed SDKs are never
    uninstalled. Does not require release metadata or download installers.

    .PARAMETER VersionBand
    Selects installed SDKs by major version, release channel, feature band, or
    exact version. Disables interactive selection.

    .PARAMETER UninstallAll
    Selects all matching SDKs without interactive selection.

    .PARAMETER Architecture
    Limits selection to x64, x86, or arm64 SDKs.

    .PARAMETER Force
    Skips the explicit uninstall confirmation (but not -Confirm).

    .EXAMPLE
    Uninstall-DotNetSdk

    .EXAMPLE
    Uninstall-DotNetSdk -VersionBand 8.0.4xx -WhatIf

    .EXAMPLE
    Uninstall-DotNetSdk -UninstallAll -Force
    #>
    [CmdletBinding(DefaultParameterSetName = 'Interactive',
        SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'VersionBands')]
        [Alias('VersionBands')]
        [ValidateNotNullOrEmpty()]
        [string[]] $VersionBand,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch] $UninstallAll,

        [ValidateSet('x64', 'x86', 'arm64')]
        [string[]] $Architecture,

        [switch] $Force
    )

    if ($env:OS -ne 'Windows_NT') {
        throw 'This command uninstalls SDKs registered by official Windows EXE installers and can only run on Windows.'
    }

    $installations = @(Get-DotNetInstallationInventory | Where-Object {
        $_.ProductType -eq 'Sdk' -and
            $_.InstallerKind -eq 'Bundle' -and
            $_.IsUninstallable
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
