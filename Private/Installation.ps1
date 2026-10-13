function Test-DotNetAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        $identity.Dispose()
    }
}

function Get-DotNetElevationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int] $OperationCount,

        [Nullable[bool]] $Elevate
    )

    $isAdministrator = Test-DotNetAdministrator
    $elevateBatch = if ($null -eq $Elevate) { $OperationCount -gt 1 } else { $Elevate }
    $useWorker = $elevateBatch -and -not $isAdministrator
    [pscustomobject] @{
        IsAdministrator = $isAdministrator
        UseWorker = $useWorker
        ApprovalRequestCount = if ($isAdministrator) { 0 } elseif ($useWorker) { 1 } else { $OperationCount }
    }
}

function Show-DotNetElevationPreview {
    param(
        [Parameter(Mandatory = $true)]
        [int] $OperationCount,

        [Nullable[bool]] $Elevate
    )

    $plan = Get-DotNetElevationPlan -OperationCount $OperationCount -Elevate $Elevate
    if ($plan.IsAdministrator) {
        Write-Host 'What if: Elevation: no administrator approval request (this PowerShell session is already elevated).'
    }
    elseif ($plan.UseWorker) {
        Write-Host "What if: Elevation: one administrator approval request for $OperationCount operation(s) using an elevated PowerShell worker."
    }
    else {
        Write-Host "What if: Elevation: $($plan.ApprovalRequestCount) administrator approval request(s), one per installer; no elevated PowerShell worker."
    }
}

function Invoke-DotNetElevationWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PlanPath,

        [Parameter(Mandatory = $true)]
        [string] $ResultPath
    )

    $result = [pscustomobject] @{
        Succeeded = $false
        RestartRequired = $false
        Error = ''
    }
    try {
        if (-not (Test-DotNetAdministrator)) {
            throw 'The batch worker is not running with administrator privileges.'
        }
        $plan = Import-Clixml -LiteralPath $PlanPath
        switch ($plan.Action) {
            'Install' {
                $candidates = @($plan.Items)
                # Recheck downloaded files inside the elevated process before execution.
                foreach ($candidate in $candidates) {
                    [void] (Assert-InstallerTrust -Candidate $candidate)
                }
                $result.RestartRequired = Install-DotNetCandidates -Candidates $candidates `
                    -ShowInstallerUi $plan.ShowInstallerUi -Elevate:$false
            }
            'Uninstall' {
                $inventory = @(Get-DotNetInstallationInventory)
                $installations = @()
                foreach ($requested in @($plan.Items)) {
                    $matches = @($inventory | Where-Object {
                        $_.InstallerKind -eq 'Bundle' -and $_.IsUninstallable -and
                            $_.RegistryView -eq $requested.RegistryView -and
                            $_.RegistrySubkey -eq $requested.RegistrySubkey -and
                            $_.BundleId -eq $requested.BundleId -and
                            $_.ProductType -eq $requested.ProductType -and
                            $_.Version -eq $requested.Version -and
                            $_.Architecture -eq $requested.Architecture
                    })
                    if ($matches.Count -ne 1) {
                        throw "The selected installation is no longer uniquely uninstallable: $($requested.DisplayName)."
                    }
                    $installations += $matches[0]
                }
                $result.RestartRequired = Invoke-DotNetUninstallPlan `
                    -Installations $installations -Elevate:$false
            }
            default {
                throw "Unsupported elevated operation '$($plan.Action)'."
            }
        }
        $result.Succeeded = $true
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Error -ErrorRecord $_ -ErrorAction Continue
    }
    $result | Export-Clixml -LiteralPath $ResultPath
    if ($result.Succeeded) { return 0 }
    return 1
}

function Invoke-DotNetElevatedOperation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Install', 'Uninstall')]
        [string] $Action,

        [Parameter(Mandatory = $true)]
        [object[]] $Items,

        [bool] $ShowInstallerUi = $false
    )

    $directory = Join-Path ([IO.Path]::GetTempPath()) (
        'dotnet-steward-elevation-{0}' -f [guid]::NewGuid().ToString('N')
    )
    [void] (New-Item -Path $directory -ItemType Directory)
    try {
        $planPath = Join-Path $directory 'plan.clixml'
        $resultPath = Join-Path $directory 'result.clixml'
        [pscustomobject] @{
            Action = $Action
            Items = $Items
            ShowInstallerUi = $ShowInstallerUi
        } | Export-Clixml -LiteralPath $planPath

        $modulePath = $ExecutionContext.SessionState.Module.Path
        $command = @'
$ErrorActionPreference = 'Stop'
try {{
    $module = Import-Module -Name '{0}' -Force -PassThru
    $exitCode = & $module {{
        param($planPath, $resultPath)
        Invoke-DotNetElevationWorker -PlanPath $planPath -ResultPath $resultPath
    }} '{1}' '{2}'
    exit $exitCode
}}
catch {{
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}}
'@ -f $modulePath.Replace("'", "''"), $planPath.Replace("'", "''"), $resultPath.Replace("'", "''")
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $executableName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $executable = Join-Path $PSHOME $executableName
        $arguments = @(
            '-NoLogo', '-NoProfile',
            '-ExecutionPolicy', [string] (Get-ExecutionPolicy),
            '-EncodedCommand', $encodedCommand
        )
        Write-Host "Windows will request administrator approval once for $($Items.Count) selected operation(s)."
        try {
            $process = Start-Process -FilePath $executable -ArgumentList $arguments `
                -Verb RunAs -Wait -PassThru
        }
        catch {
            $nativeErrorCodeProperty = $_.Exception.PSObject.Properties['NativeErrorCode']
            if ($null -ne $nativeErrorCodeProperty -and $nativeErrorCodeProperty.Value -eq 1223) {
                throw 'Administrator approval was cancelled for the selected .NET operations.'
            }
            throw
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "The elevated .NET worker exited with code $($process.ExitCode) without reporting a result."
        }
        $result = Import-Clixml -LiteralPath $resultPath
        if ($process.ExitCode -ne 0 -or -not $result.Succeeded) {
            throw "The elevated .NET operation failed (exit code $($process.ExitCode)): $($result.Error)"
        }
        return [bool] $result.RestartRequired
    }
    finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

function Install-DotNetCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Candidates,

        [Parameter(Mandatory = $true)]
        [bool] $ShowInstallerUi,

        [Nullable[bool]] $Elevate
    )

    $orderedCandidates = @(Sort-UpdateCandidates -Candidates $Candidates)
    $restartRequired = $false

    $elevationPlan = Get-DotNetElevationPlan -OperationCount $orderedCandidates.Count -Elevate $Elevate
    $isAdministrator = $elevationPlan.IsAdministrator
    if ($elevationPlan.UseWorker) {
        return Invoke-DotNetElevatedOperation -Action Install -Items $orderedCandidates `
            -ShowInstallerUi $ShowInstallerUi
    }

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
        [bool] $ShowInstallerUi,

        [ValidateSet('updates', 'installations')]
        [string] $CompletionSubject = 'updates',

        [Nullable[bool]] $Elevate
    )

    $downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'dotnet-steward-{0}' -f [guid]::NewGuid().ToString('N')
    )
    [void] (New-Item -Path $downloadDirectory -ItemType Directory)

    try {
        Save-InstallersInParallel -Candidates $Candidates -DestinationDirectory $downloadDirectory

        Write-Host 'Verifying installer hashes and Authenticode signatures...'
        foreach ($candidate in $Candidates) {
            $trust = Assert-InstallerTrust -Candidate $candidate
            Write-Host "  $($candidate.ProductLabel) $($candidate.TargetVersion) ($($candidate.Rid)): valid signature from $($trust.SignerSubject)"
        }

        $restartRequired = Install-DotNetCandidates -Candidates $Candidates `
            -ShowInstallerUi $ShowInstallerUi -Elevate $Elevate

        Write-Host ''
        if ($restartRequired) {
            Write-Host "Selected .NET $CompletionSubject were installed. Restart Windows to complete all changes."
        }
        else {
            Write-Host "Selected .NET $CompletionSubject were installed successfully."
        }
    }
    finally {
        if (Test-Path -LiteralPath $downloadDirectory) {
            Remove-Item -LiteralPath $downloadDirectory -Recurse -Force
        }
    }
}
