@{
    RootModule = 'DotNetSteward.psm1'
    ModuleVersion = '0.1.0'
    GUID = '80fe4417-3563-4336-b389-58cb1df77ae0'
    Author = 'Damian Edwards'
    Copyright = '(c) 2026 Damian Edwards and contributors'
    Description = 'Inventories and updates .NET SDK and runtime installations managed by Windows installers.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FormatsToProcess = @('DotNetSteward.Format.ps1xml')
    FunctionsToExport = @(
        'Get-DotNetInstallation',
        'Update-DotNetRuntime',
        'Update-DotNetSdk'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @('DotNet', 'SDK', 'Runtime', 'Windows', 'Update', 'PowerShell')
            LicenseUri = 'https://github.com/DamianEdwards/dotnet-steward/blob/main/LICENSE'
            ProjectUri = 'https://github.com/DamianEdwards/dotnet-steward'
        }
    }
}
