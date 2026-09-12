function Update-DotNetRuntime {
    <#
    .SYNOPSIS
    Finds and installs updates for standalone .NET runtime bundles.

    .DESCRIPTION
    Finds official updates for standalone .NET Runtime, ASP.NET Core Runtime,
    and .NET Windows Desktop Runtime EXE bundles registered with Windows.
    Runtime payloads managed by an SDK, Visual Studio, or another installer are
    visible through Get-DotNetInstallation but are never updated directly.

    Patch scope, the default, stays within each installed major/minor runtime
    channel. Major scope updates each selected runtime product and architecture
    to the newest eligible release. Stable installations update only to stable
    releases unless IncludePreview is specified; an installed prerelease can
    advance through later previews, release candidates, and stable releases.

    .PARAMETER ProductType
    Limits updates to Runtime, AspNetCoreRuntime, or WindowsDesktopRuntime.

    .PARAMETER Architecture
    Limits updates to x64, x86, or arm64 standalone bundles.

    .PARAMETER UpdateScope
    Limits updates to Patch or Major. The default is Patch.

    .PARAMETER VersionBand
    Runs non-interactively and considers only installed runtimes matching a
    major version, release channel, or exact installed version.

    .PARAMETER UpdateAll
    Runs non-interactively and installs every matching runtime update found.

    .PARAMETER IncludePreview
    Allows a stable runtime to update to a newer official preview or release
    candidate. This is not required for installed prerelease runtimes.

    .PARAMETER InteractiveInstaller
    Shows the installer's UI instead of using /install /quiet /norestart.

    .EXAMPLE
    Update-DotNetRuntime

    Interactively selects patch updates for all standalone runtime bundles.

    .EXAMPLE
    Update-DotNetRuntime -ProductType WindowsDesktopRuntime -UpdateAll

    Updates every standalone Windows Desktop Runtime to its latest patch.

    .EXAMPLE
    Update-DotNetRuntime -VersionBand 8.0 -Architecture x64 -UpdateScope Major

    Updates matching x64 runtime bundles to the newest stable major release.
    #>

    [CmdletBinding(
        DefaultParameterSetName = 'Interactive',
        SupportsShouldProcess = $true,
        ConfirmImpact = 'Medium'
    )]
    param(
        [ValidateSet('Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string[]] $ProductType = @(
            'Runtime',
            'AspNetCoreRuntime',
            'WindowsDesktopRuntime'
        ),

        [ValidateSet('x64', 'x86', 'arm64')]
        [string[]] $Architecture,

        [Alias('Scope')]
        [ValidateSet('Patch', 'Major')]
        [string] $UpdateScope = 'Patch',

        [Parameter(Mandatory = $true, ParameterSetName = 'VersionBands')]
        [Alias('VersionBands', 'Version')]
        [ValidateNotNullOrEmpty()]
        [string[]] $VersionBand,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch] $UpdateAll,

        [Alias('AllowPreview')]
        [switch] $IncludePreview,

        [switch] $InteractiveInstaller
    )

    $originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            $originalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        if ($env:OS -ne 'Windows_NT') {
            throw 'This command updates runtimes installed by official Windows EXE installers and can only run on Windows.'
        }
        if ($PSVersionTable.PSVersion -lt [version] '5.1') {
            throw 'PowerShell 5.1 or later is required.'
        }

        $installedRuntimes = @(Get-DotNetInstallationInventory | Where-Object {
            $_.InstallerKind -eq 'Bundle' -and
                $_.ProductType -ne 'Sdk' -and
                $_.IsUpdateable -and
                $ProductType -contains $_.ProductType
        })
        if ($PSBoundParameters.ContainsKey('Architecture')) {
            $installedRuntimes = @($installedRuntimes | Where-Object {
                $Architecture -contains $_.Architecture
            })
        }
        if ($installedRuntimes.Count -eq 0) {
            Write-Host 'No matching standalone .NET runtime installer registrations were found.'
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'VersionBands') {
            $normalizedVersionBands = @()
            foreach ($selectorValue in $VersionBand) {
                foreach ($selectorPart in $selectorValue.Split(',')) {
                    if (-not [string]::IsNullOrWhiteSpace($selectorPart)) {
                        $normalizedVersionBands += $selectorPart.Trim()
                    }
                }
            }
            if ($normalizedVersionBands.Count -eq 0) {
                throw '-VersionBand must contain at least one version selector.'
            }
            Assert-VersionBandSelectors -Selectors $normalizedVersionBands
            $installedRuntimes = @(Select-InstallationsByVersionBand `
                -Installations $installedRuntimes -Selectors $normalizedVersionBands)
            if ($installedRuntimes.Count -eq 0) {
                Write-Host "No standalone .NET runtimes matched -VersionBand: $($normalizedVersionBands -join ', ')."
                return
            }
        }

        $releaseIndex = @(Get-ReleaseIndex)
        $candidates = @(Get-RuntimeUpdateCandidates -InstalledRuntimes $installedRuntimes `
            -ReleaseIndex $releaseIndex -Scope $UpdateScope `
            -AllowPreview ([bool] $IncludePreview))
        if ($candidates.Count -eq 0) {
            Write-Host "No eligible standalone .NET runtime updates were found within $UpdateScope scope."
            return
        }

        $candidates = @(Sort-UpdateCandidates -Candidates $candidates)
        Show-AvailableUpdates -Candidates $candidates

        if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
            $candidates = @(Select-UpdateCandidates -Candidates $candidates)
            if ($candidates.Count -eq 0) {
                Write-Host 'No runtime updates were selected.'
                return
            }
            if (-not (Confirm-SelectedUpdates -Count $candidates.Count)) {
                Write-Host 'Update cancelled.'
                return
            }
        }

        $targets = @()
        foreach ($candidate in $candidates) {
            $targets += "$($candidate.ProductLabel) $($candidate.TargetVersion) ($($candidate.Rid))"
        }
        if (-not $PSCmdlet.ShouldProcess(
            ($targets -join ', '),
            'Download and install official runtime updates'
        )) {
            return
        }

        Invoke-DotNetInstallerPlan -Candidates $candidates `
            -ShowInstallerUi ([bool] $InteractiveInstaller)
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
    }
}
