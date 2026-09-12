function Update-DotNetSdk {
    <#
    .SYNOPSIS
    Finds and installs updates for SDKs installed by the official .NET SDK Windows installer.

    .DESCRIPTION
    Uses the Windows installer bundle registrations to discover standalone .NET
    SDK installations, then uses Microsoft's official release metadata to find
    SDK updates for each registered architecture.

    By default, the command presents a keyboard-driven checklist with every
    update selected. Use Up/Down to move, Space to toggle, A/N to select all or
    none, Enter to accept, or Escape to cancel.

    Patch scope stays within each installed SDK feature band (for example,
    8.0.4xx). FeatureBand scope, the default, updates each installed release
    channel to its latest feature band. Major scope updates the selected
    installed SDKs to the newest eligible .NET SDK release.

    An installed preview or release-candidate SDK can update to a newer official
    preview, release candidate, or stable release. Stable SDKs update only to
    stable releases unless IncludePreview is specified.

    Supplying VersionBand or UpdateAll disables selection and confirmation
    prompts. Installers still request UAC elevation when the shell is not already
    elevated. Installer UI is disabled by default.

    .PARAMETER UpdateScope
    Limits updates to Patch, FeatureBand, or Major. The default is FeatureBand.

    .PARAMETER VersionBand
    Runs non-interactively and considers only installed SDKs matching one or more
    selectors: a major version (8), release channel (8.0), SDK feature band
    (8.0.4xx), or exact installed SDK version (8.0.424).

    .PARAMETER UpdateAll
    Runs non-interactively and installs every update found within UpdateScope.

    .PARAMETER IncludePreview
    Allows a stable SDK to update to a newer official preview or release
    candidate. This is not required when the installed SDK is already a
    prerelease.

    .PARAMETER InteractiveInstaller
    Shows the installer's full UI. Without this switch, installers run with
    /install /quiet /norestart.

    .EXAMPLE
    Update-DotNetSdk

    Interactively selects updates, staying within each installed release channel.

    .EXAMPLE
    Update-DotNetSdk -UpdateAll

    Installs every available feature-band update without selection prompts.

    .EXAMPLE
    Update-DotNetSdk -VersionBand 8.0.4xx, 9.0 -UpdateScope Patch

    Installs patch updates for matching installed SDK feature bands.

    .EXAMPLE
    Update-DotNetSdk -UpdateAll -UpdateScope Major -IncludePreview

    Allows stable SDKs to update to the newest official preview or stable SDK.

    .NOTES
    Only releases in Microsoft's official releases index are considered; daily
    builds are not supported. Visual Studio-owned SDKs and SDKs installed from
    archives or local repositories are not managed.
    #>

    [CmdletBinding(
        DefaultParameterSetName = 'Interactive',
        SupportsShouldProcess = $true,
        ConfirmImpact = 'Medium'
    )]
    param(
        [Alias('Scope')]
        [ValidateSet('Patch', 'FeatureBand', 'Major')]
        [string] $UpdateScope = 'FeatureBand',

        [Parameter(Mandatory = $true, ParameterSetName = 'VersionBands')]
        [Alias('VersionBands')]
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

    $runningOnWindows = $env:OS -eq 'Windows_NT'
    if (-not $runningOnWindows) {
        throw 'This command updates SDKs installed by the official Windows EXE installer and can only run on Windows.'
    }

    if ($PSVersionTable.PSVersion -lt [version] '5.1') {
        throw 'PowerShell 5.1 or later is required.'
    }

    $installedSdks = @(Get-DotNetSdkBundleInventory)
    if ($installedSdks.Count -eq 0) {
        Write-Host 'No standalone .NET SDK installer registrations were found.'
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
            throw '-VersionBand must contain at least one version-band selector.'
        }
        Assert-VersionBandSelectors -Selectors $normalizedVersionBands
        $installedSdks = @(Select-InstallationsByVersionBand `
            -Installations $installedSdks -Selectors $normalizedVersionBands)
        if ($installedSdks.Count -eq 0) {
            Write-Host "No installed .NET SDKs matched -VersionBand: $($normalizedVersionBands -join ', ')."
            return
        }
    }

    $releaseIndex = @(Get-ReleaseIndex)
    $candidates = @(Get-UpdateCandidates -InstalledSdks $installedSdks `
        -ReleaseIndex $releaseIndex -Scope $UpdateScope -AllowPreview ([bool] $IncludePreview))

    if ($candidates.Count -eq 0) {
        Write-Host "No eligible .NET SDK updates were found within $UpdateScope scope."
        return
    }

    $candidates = @(Sort-UpdateCandidates -Candidates $candidates)
    Show-AvailableUpdates -Candidates $candidates

    if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
        $candidates = @(Select-UpdateCandidates -Candidates $candidates)
        if ($candidates.Count -eq 0) {
            Write-Host 'No SDK updates were selected.'
            return
        }

        if (-not (Confirm-SelectedUpdates -Count $candidates.Count)) {
            Write-Host 'Update cancelled.'
            return
        }
    }

    $targetVersions = @()
    foreach ($candidate in $candidates) {
        $targetVersions += "$($candidate.TargetVersion) ($($candidate.Rid))"
    }
    $targetDescription = $targetVersions -join ', '
    if (-not $PSCmdlet.ShouldProcess(
        ".NET SDK version(s) $targetDescription",
        'Download and install official SDK updates'
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
