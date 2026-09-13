function Install-DotNetRuntime {
    <#
    .SYNOPSIS
    Installs official .NET runtime Windows EXE installers.

    .DESCRIPTION
    Resolves .NET Runtime, ASP.NET Core Runtime, or .NET Windows Desktop Runtime
    releases through Microsoft's official metadata, downloads selected
    installers in parallel, validates their declared SHA-256 or SHA-512 hashes
    and Authenticode signatures, and installs them sequentially from lowest to
    highest version.

    This command does not require an existing .NET installation. It installs
    the base .NET Runtime unless ProductType is specified.

    .PARAMETER ProductType
    Selects Runtime, AspNetCoreRuntime, or WindowsDesktopRuntime. Defaults to
    Runtime.

    .PARAMETER Version
    Installs one or more exact runtime versions. An exact prerelease version
    does not require IncludePreview.

    .PARAMETER Channel
    Installs the latest stable runtime in each specified major/minor channel.

    .PARAMETER Architecture
    Selects x64, x86, or arm64 Windows installers. Defaults to the native
    Windows architecture.

    .PARAMETER IncludePreview
    Allows channel selection to resolve to a preview or release candidate when
    it is newer than the latest stable release.

    .PARAMETER InteractiveInstaller
    Shows the installer's UI instead of using /install /quiet /norestart.

    .EXAMPLE
    Install-DotNetRuntime -Version 8.0.25

    Installs that exact .NET Runtime version.

    .EXAMPLE
    Install-DotNetRuntime -ProductType AspNetCoreRuntime -Channel 8.0

    Installs the latest stable ASP.NET Core Runtime in the .NET 8 channel.

    .EXAMPLE
    Install-DotNetRuntime -ProductType WindowsDesktopRuntime -Channel 11.0 -IncludePreview

    Installs the latest .NET 11 Windows Desktop Runtime, including prereleases.
    #>

    [CmdletBinding(
        DefaultParameterSetName = 'Version',
        SupportsShouldProcess = $true,
        ConfirmImpact = 'Medium'
    )]
    param(
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Runtime', 'AspNetCoreRuntime', 'WindowsDesktopRuntime')]
        [string[]] $ProductType = @('Runtime'),

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
        ProductType = $ProductType
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
    }

    $releases = @(Find-DotNetRuntime @findParameters)
    Assert-RequestedReleasesResolved -Releases $releases `
        -SelectorKind $selectorKind -Selectors $selectors `
        -Architectures $Architecture -ProductTypes $ProductType

    $candidates = @(ConvertTo-DotNetInstallCandidates -Releases $releases)
    $targets = @($candidates | ForEach-Object {
        "$($_.ProductLabel) $($_.TargetVersion) ($($_.Rid))"
    })
    if (-not $PSCmdlet.ShouldProcess(
        ($targets -join ', '),
        'Download and install official runtime'
    )) {
        return
    }

    Invoke-DotNetInstallerPlan -Candidates $candidates `
        -ShowInstallerUi ([bool] $InteractiveInstaller) `
        -CompletionSubject installations
}
