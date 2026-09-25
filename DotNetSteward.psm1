Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReleaseIndexUri = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'
$script:ExpectedSignerSubjects = @{
    'CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' = '.NET'
    'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' = 'Microsoft Corporation'
}
$script:ExpectedRootSubject = 'CN=Microsoft Root Certificate Authority 2011, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$script:ExpectedRootThumbprint = '8F43288AD272F3103B6FB1428485EA3014C0BCFE'
$script:TrustedSigningAuthorities = @{
    '5039C8DC9ACE1CE039587E43486DE073FA459222' = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US'
    'F252E794FE438E35ACE6E53762C0A234A2C52135' = 'CN=Microsoft Code Signing PCA 2011, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
}

$privateScripts = @(
    'Private\Versioning.ps1'
    'Private\Discovery.ps1'
    'Private\VersionSelection.ps1'
    'Private\ReleaseMetadata.ps1'
    'Private\AvailableReleases.ps1'
    'Private\UpdatePlanning.ps1'
    'Private\InteractiveSelection.ps1'
    'Private\Downloads.ps1'
    'Private\InstallerTrust.ps1'
    'Private\Installation.ps1'
    'Private\Uninstallation.ps1'
)
$publicScripts = @(
    'Public\Find-DotNetRuntime.ps1'
    'Public\Find-DotNetSdk.ps1'
    'Public\Get-DotNetInstallation.ps1'
    'Public\Install-DotNetRuntime.ps1'
    'Public\Install-DotNetSdk.ps1'
    'Public\Update-DotNetSdk.ps1'
    'Public\Update-DotNetRuntime.ps1'
    'Public\Uninstall-DotNetSdk.ps1'
    'Public\Uninstall-DotNetRuntime.ps1'
)

foreach ($relativePath in @($privateScripts + $publicScripts)) {
    . (Join-Path $PSScriptRoot $relativePath)
}

Export-ModuleMember -Function @(
    'Find-DotNetRuntime'
    'Find-DotNetSdk'
    'Get-DotNetInstallation'
    'Install-DotNetRuntime'
    'Install-DotNetSdk'
    'Update-DotNetRuntime'
    'Update-DotNetSdk'
    'Uninstall-DotNetRuntime'
    'Uninstall-DotNetSdk'
)
