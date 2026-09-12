function Save-InstallersInParallel {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Candidates,

        [Parameter(Mandatory = $true)]
        [string] $DestinationDirectory
    )

    Import-Module BitsTransfer -ErrorAction Stop
    $records = New-Object System.Collections.Generic.List[object]

    try {
        Write-Host "Downloading $($Candidates.Count) .NET installer(s) in parallel..."
        for ($index = 0; $index -lt $Candidates.Count; $index++) {
            $candidate = $Candidates[$index]
            $destination = Join-Path $DestinationDirectory (
                '{0}-{1}-{2}.exe' -f
                    $candidate.ProductType.ToLowerInvariant(),
                    $candidate.TargetVersion,
                    $candidate.Rid
            )
            $candidate | Add-Member -NotePropertyName InstallerPath -NotePropertyValue $destination -Force

            $job = Start-BitsTransfer -Source $candidate.Url -Destination $destination `
                -DisplayName "Download $($candidate.ProductLabel) $($candidate.TargetVersion) ($($candidate.Rid))" `
                -Description "Official $($candidate.ProductLabel) $($candidate.Rid) installer" `
                -Priority Foreground -RetryInterval 60 -RetryTimeout 300 -Asynchronous

            $records.Add([pscustomobject] @{
                Index = $index
                Candidate = $candidate
                JobId = $job.JobId
                Complete = $false
            })
        }

        while (@($records | Where-Object { -not $_.Complete }).Count -gt 0) {
            foreach ($record in @($records | Where-Object { -not $_.Complete })) {
                $job = Get-BitsTransfer -JobId $record.JobId
                $progressId = 1000 + $record.Index

                switch ([string] $job.JobState) {
                    'Transferred' {
                        Complete-BitsTransfer -BitsJob $job
                        $record.Complete = $true
                        Write-Progress -Id $progressId `
                            -Activity "Downloading $($record.Candidate.ProductLabel) $($record.Candidate.TargetVersion) ($($record.Candidate.Rid))" `
                            -Status 'Complete' -Completed
                    }
                    'Error' {
                        $description = 'Unknown BITS error.'
                        if ($null -ne $job.Error -and -not [string]::IsNullOrWhiteSpace($job.Error.Description)) {
                            $description = $job.Error.Description
                        }
                        throw "Download of $($record.Candidate.ProductLabel) $($record.Candidate.TargetVersion) failed: $description"
                    }
                    'Cancelled' {
                        throw "Download of $($record.Candidate.ProductLabel) $($record.Candidate.TargetVersion) was cancelled."
                    }
                    default {
                        $percent = 0
                        $status = [string] $job.JobState
                        if ($job.BytesTotal -gt 0) {
                            $percent = [math]::Min(
                                100,
                                [int] (($job.BytesTransferred * 100L) / $job.BytesTotal)
                            )
                            $status = '{0:N1} MB of {1:N1} MB' -f (
                                $job.BytesTransferred / 1MB
                            ), (
                                $job.BytesTotal / 1MB
                            )
                        }
                        Write-Progress -Id $progressId `
                            -Activity "Downloading $($record.Candidate.ProductLabel) $($record.Candidate.TargetVersion) ($($record.Candidate.Rid))" `
                            -Status $status -PercentComplete $percent
                    }
                }
            }

            if (@($records | Where-Object { -not $_.Complete }).Count -gt 0) {
                Start-Sleep -Milliseconds 250
            }
        }
    }
    finally {
        foreach ($record in $records) {
            Write-Progress -Id (1000 + $record.Index) `
                -Activity "Downloading $($record.Candidate.ProductLabel) $($record.Candidate.TargetVersion) ($($record.Candidate.Rid))" `
                -Completed

            if (-not $record.Complete) {
                $job = Get-BitsTransfer -JobId $record.JobId -ErrorAction SilentlyContinue
                if ($null -ne $job) {
                    Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
