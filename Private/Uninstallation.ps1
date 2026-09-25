function Get-DotNetUninstallExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Installation
    )

    $path = [string] $Installation.BundleCachePath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $command = [string] $Installation.UninstallString
        if ($command -match '^\s*"(?<path>[^"]+\.exe)"(?:\s|$)') {
            $path = $Matches.path
        }
        elseif ($command -match '^\s*(?<path>[^\s"]+\.exe)(?:\s|$)') {
            $path = $Matches.path
        }
    }

    if (-not [IO.Path]::IsPathRooted($path) -or
        [IO.Path]::GetExtension($path) -ine '.exe' -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The cached uninstall executable for $($Installation.DisplayName) was not found. No uninstall was attempted."
    }

    $fileName = [IO.Path]::GetFileName($path)
    if ($fileName -notmatch '(?i)^(?:dotnet-sdk|dotnet-runtime|aspnetcore-runtime|windowsdesktop-runtime)-\d+\.\d+\.\d+(?:-[0-9a-z.-]+)?-win-(?:x64|x86|arm64)\.exe$' -and
        $fileName -notmatch '(?i)^dotnet-(?:dev-)?win-(?:x64|x86)\.\d+\.\d+\.\d+(?:-[0-9a-z.-]+)?\.exe$') {
        throw "The cached uninstall executable does not have a recognized .NET bundle name: '$fileName'."
    }
    $executableIdentity = Get-DotNetBundleIdentity -DisplayName $Installation.DisplayName `
        -BundleCachePath $path -UninstallString ''
    if ($null -eq $executableIdentity -or
        $executableIdentity.ProductType -ne $Installation.ProductType -or
        $executableIdentity.Version -ne $Installation.Version -or
        $executableIdentity.Architecture -ne $Installation.Architecture) {
        throw "The cached uninstall executable does not match $($Installation.DisplayName). No uninstall was attempted."
    }

    return $path
}

function Invoke-DotNetUninstallPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Installations
    )

    $restartRequired = $false
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    foreach ($installation in $Installations) {
        $path = Get-DotNetUninstallExecutable -Installation $installation
        [void] (Assert-InstallerSignature -InstallerPath $path `
            -ProductLabel $installation.ProductType -Version $installation.Version)

        Write-Host "Uninstalling $($installation.ProductType) $($installation.Version) ($($installation.Rid))..."
        if (-not $isAdministrator) {
            Write-Host '  Windows will request administrator approval for this machine-wide uninstall.'
        }

        try {
            $process = Start-Process -FilePath $path `
                -ArgumentList @('/uninstall', '/quiet', '/norestart') -Verb RunAs -Wait -PassThru
        }
        catch {
            $nativeErrorCodeProperty = $_.Exception.PSObject.Properties['NativeErrorCode']
            if ($null -ne $nativeErrorCodeProperty -and $nativeErrorCodeProperty.Value -eq 1223) {
                throw "Administrator approval was cancelled for $($installation.DisplayName)."
            }
            throw
        }

        if ($process.ExitCode -eq 3010) {
            $restartRequired = $true
            Write-Host "  $($installation.DisplayName) uninstalled; Windows reports that a restart is required."
        }
        elseif ($process.ExitCode -eq 0) {
            Write-Host "  $($installation.DisplayName) uninstalled successfully."
        }
        else {
            throw "The $($installation.DisplayName) uninstaller exited with code $($process.ExitCode)."
        }
    }

    if ($restartRequired) {
        Write-Host 'Restart Windows to complete the selected .NET uninstalls.'
    }
}

function Select-DotNetUninstallVersionBand {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Installations,

        [Parameter(Mandatory = $true)]
        [string[]] $VersionBand
    )

    $selectors = @()
    foreach ($value in $VersionBand) {
        foreach ($part in $value.Split(',')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $selectors += $part.Trim()
            }
        }
    }
    if ($selectors.Count -eq 0) {
        throw '-VersionBand must contain at least one version selector.'
    }
    Assert-VersionBandSelectors -Selectors $selectors
    return Select-InstallationsByVersionBand -Installations $Installations -Selectors $selectors
}

function Invoke-DotNetUninstallSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Installations,

        [Parameter(Mandatory = $true)]
        [string] $ParameterSetName,

        [Parameter(Mandatory = $true)]
        [bool] $Force,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet] $Cmdlet
    )

    if ($Installations.Count -eq 0) {
        Write-Host 'No matching uninstallable standalone .NET installations were found.'
        return
    }

    $Installations = @(Sort-DotNetInstallations -Installations $Installations)
    Write-Host ''
    Write-Host 'Uninstallable standalone .NET installations:'
    $Installations |
        Select-Object ProductType, Version, Architecture |
        Format-Table -AutoSize | Out-Host

    if ($ParameterSetName -eq 'Interactive') {
        $Installations = @(Select-UpdateCandidates -Candidates $Installations -Action uninstall)
        if ($Installations.Count -eq 0) {
            Write-Host 'No .NET installations were selected.'
            return
        }
    }

    $targets = @($Installations | ForEach-Object {
        "$($_.ProductType) $($_.Version) ($($_.Rid))"
    })
    if (-not $Cmdlet.ShouldProcess(($targets -join ', '), 'Uninstall standalone .NET installations')) {
        return
    }

    if (-not $Force) {
        $answer = Read-Host "Uninstall $($Installations.Count) selected .NET installation(s)? [y/N]"
        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host 'Uninstall cancelled.'
            return
        }
    }

    Invoke-DotNetUninstallPlan -Installations $Installations
}
