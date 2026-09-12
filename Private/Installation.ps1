function Install-DotNetUpdates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Candidates,

        [Parameter(Mandatory = $true)]
        [bool] $ShowInstallerUi
    )

    $orderedCandidates = @(Sort-UpdateCandidates -Candidates $Candidates)
    $restartRequired = $false

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    foreach ($candidate in $orderedCandidates) {
        Write-Host ''
        Write-Host "Installing $($candidate.ProductLabel) $($candidate.TargetVersion) ($($candidate.Rid))..."
        if (-not $isAdministrator) {
            Write-Host '  Windows will request administrator approval for this machine-wide install.'
        }

        if ($ShowInstallerUi) {
            $arguments = @('/install', '/norestart')
        }
        else {
            $arguments = @('/install', '/quiet', '/norestart')
        }

        try {
            $process = Start-Process -FilePath $candidate.InstallerPath `
                -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        }
        catch {
            $nativeErrorCodeProperty = $_.Exception.PSObject.Properties['NativeErrorCode']
            if ($null -ne $nativeErrorCodeProperty -and $nativeErrorCodeProperty.Value -eq 1223) {
                throw "Administrator approval was cancelled for $($candidate.ProductLabel) $($candidate.TargetVersion)."
            }
            throw
        }

        if ($process.ExitCode -eq 3010) {
            $restartRequired = $true
            Write-Host "  $($candidate.ProductLabel) $($candidate.TargetVersion) installed successfully; Windows reports that a restart is required."
        }
        elseif ($process.ExitCode -eq 0) {
            Write-Host "  $($candidate.ProductLabel) $($candidate.TargetVersion) installed successfully."
        }
        else {
            throw "The $($candidate.ProductLabel) $($candidate.TargetVersion) installer exited with code $($process.ExitCode)."
        }
    }

    return $restartRequired
}

function Invoke-DotNetInstallerPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Candidates,

        [Parameter(Mandatory = $true)]
        [bool] $ShowInstallerUi
    )

    $downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'update-dotnet-{0}' -f [guid]::NewGuid().ToString('N')
    )
    [void] (New-Item -Path $downloadDirectory -ItemType Directory)

    try {
        Save-InstallersInParallel -Candidates $Candidates -DestinationDirectory $downloadDirectory

        Write-Host 'Verifying installer hashes and Authenticode signatures...'
        foreach ($candidate in $Candidates) {
            $trust = Assert-InstallerTrust -Candidate $candidate
            Write-Host "  $($candidate.ProductLabel) $($candidate.TargetVersion) ($($candidate.Rid)): valid signature from $($trust.SignerSubject)"
        }

        $restartRequired = Install-DotNetUpdates -Candidates $Candidates `
            -ShowInstallerUi $ShowInstallerUi

        Write-Host ''
        if ($restartRequired) {
            Write-Host 'Selected .NET updates were installed. Restart Windows to complete all changes.'
        }
        else {
            Write-Host 'Selected .NET updates were installed successfully.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $downloadDirectory) {
            Remove-Item -LiteralPath $downloadDirectory -Recurse -Force
        }
    }
}
