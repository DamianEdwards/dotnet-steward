[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SourceCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runsJson = gh api "repos/$Repository/actions/workflows/verify.yml/runs?head_sha=$SourceCommit&branch=main&per_page=100"
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read verification runs for the release source.'
}
$runs = @(
    ($runsJson | ConvertFrom-Json).workflow_runs |
        Where-Object {
            $_.head_sha -eq $SourceCommit -and
            $_.head_branch -eq 'main' -and
            $_.event -in @('push', 'workflow_dispatch')
        } |
        Sort-Object id -Descending
)
if ($runs.Count -eq 0) {
    throw "No Verify workflow run was found for main commit '$SourceCommit'. Run Verify on that commit before starting a release."
}
$run = $runs[0]
if ($run.status -ne 'completed' -or $run.conclusion -ne 'success') {
    throw "The latest Verify workflow run ($($run.id)) for '$SourceCommit' has not succeeded. Finish verification before starting a release."
}

$jobsJson = gh api "repos/$Repository/actions/runs/$($run.id)/attempts/$($run.run_attempt)/jobs?per_page=100"
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the verification gate for the release source.'
}
$gates = @(
    ($jobsJson | ConvertFrom-Json).jobs |
        Where-Object { $_.name -eq 'Verification' -and $_.head_sha -eq $SourceCommit }
)
if ($gates.Count -ne 1 -or
    $gates[0].status -ne 'completed' -or $gates[0].conclusion -ne 'success') {
    throw "Verify run $($run.id) does not have a successful Verification gate for '$SourceCommit'."
}

[pscustomobject] @{
    SourceCommit = $SourceCommit
    VerificationRunId = $run.id
}
