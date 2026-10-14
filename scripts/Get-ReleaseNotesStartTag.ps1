[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Tag,

    [AllowEmptyCollection()]
    [object[]] $Releases = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$previousRelease = $Releases |
    Where-Object { -not $_.isDraft -and $_.tagName -ne $Tag } |
    Sort-Object -Property @{
        Expression = { [datetimeoffset] $_.publishedAt }
        Descending = $true
    }, @{
        Expression = { $_.tagName }
        Descending = $true
    } |
    Select-Object -First 1

if ($null -ne $previousRelease) {
    if ([string]::IsNullOrWhiteSpace([string] $previousRelease.tagName)) {
        throw 'The previous published release does not have a tag name.'
    }
    $previousRelease.tagName
}
