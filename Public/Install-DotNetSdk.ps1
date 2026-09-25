function Install-DotNetSdk {
    <#
    .SYNOPSIS
    Installs official .NET SDK Windows EXE installers.

    .DESCRIPTION
    Resolves exact versions, channels, or SDK feature bands through Microsoft's
    official release metadata, downloads the selected Windows EXE installers
    in parallel, validates their declared SHA-256 or SHA-512 hashes and
    Authenticode signatures, and installs them sequentially from lowest to
    highest version.

    This command does not require an existing .NET installation. Installers run
    unattended by default and request administrator approval through Windows
    when required.

    .PARAMETER Version
    Installs one or more exact SDK versions. An exact prerelease version does
    not require IncludePreview.

    .PARAMETER Channel
    Installs the latest stable SDK in each specified major/minor channel.

    .PARAMETER VersionBand
    Installs the latest stable SDK in each specified feature band.

    .PARAMETER Architecture
    Selects x64, x86, or arm64 Windows installers. Defaults to the native
    Windows architecture.

    .PARAMETER IncludePreview
    Allows channel or feature-band selection to resolve to a preview or release
    candidate when it is newer than the latest stable release.

    .PARAMETER InteractiveInstaller
    Shows the installer's UI instead of using /install /quiet /norestart.

    .EXAMPLE
    Install-DotNetSdk -Version 8.0.419

    Installs that exact SDK for the native Windows architecture.

    .EXAMPLE
    Install-DotNetSdk -Channel 8.0

    Installs the latest stable .NET 8 SDK.

    .EXAMPLE
    Install-DotNetSdk -VersionBand 8.0.4xx

    Installs the latest stable SDK in the 8.0.4xx feature band.

    .EXAMPLE
    Install-DotNetSdk -Channel 11.0 -IncludePreview

    Installs the latest available .NET 11 SDK, including prereleases.
    #>

    [CmdletBinding(
        DefaultParameterSetName = 'Version',
        SupportsShouldProcess = $true,
        ConfirmImpact = 'Medium'
    )]
    param(
        [Parameter(
            Mandatory = $true,
            Position = 0,
            ParameterSetName = 'Version'
        )]
        [ValidateNotNullOrEmpty()]
        [string[]] $Version,

        [Parameter(Mandatory = $true, ParameterSetName = 'Channel')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Channel,

        [Parameter(Mandatory = $true, ParameterSetName = 'VersionBand')]
        [ValidateNotNullOrEmpty()]
        [string[]] $VersionBand,

        [ValidateNotNullOrEmpty()]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string[]] $Architecture,

        [switch] $IncludePreview,

        [switch] $InteractiveInstaller
    )

    Assert-DotNetStewardPlatform
    if (-not $PSBoundParameters.ContainsKey('Architecture')) {
        $Architecture = @(Get-NativeDotNetArchitecture)
    }

    $findParameters = @{
        Architecture = $Architecture
    }
    $selectorKind = $PSCmdlet.ParameterSetName
    $selectors = switch ($selectorKind) {
        'Version' {
            $findParameters.Version = $Version
            $Version
        }
        'Channel' {
            $findParameters.Channel = $Channel
            if ($IncludePreview) {
                $findParameters.IncludePreview = $true
            }
            $Channel
        }
        'VersionBand' {
            $findParameters.VersionBand = $VersionBand
            if ($IncludePreview) {
                $findParameters.IncludePreview = $true
            }
            $VersionBand
        }
    }

    $releases = @(Find-DotNetSdk @findParameters)
    Assert-RequestedReleasesResolved -Releases $releases `
        -SelectorKind $selectorKind -Selectors $selectors `
        -Architectures $Architecture -ProductTypes @('Sdk')

    $candidates = @(ConvertTo-DotNetInstallCandidates -Releases $releases)
    $targets = @($candidates | ForEach-Object {
        "$($_.ProductLabel) $($_.TargetVersion) ($($_.Rid))"
    })
    if (-not $PSCmdlet.ShouldProcess(
        ($targets -join ', '),
        'Download and install official SDK'
    )) {
        return
    }

    Invoke-DotNetInstallerPlan -Candidates $candidates `
        -ShowInstallerUi ([bool] $InteractiveInstaller) `
        -CompletionSubject installations
}
