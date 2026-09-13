# DotNetSteward

[![Verify](https://github.com/DamianEdwards/dotnet-steward/actions/workflows/verify.yml/badge.svg)](https://github.com/DamianEdwards/dotnet-steward/actions/workflows/verify.yml)

DotNetSteward is a Windows PowerShell module for inventorying and updating
official Microsoft .NET SDK and runtime installations managed by Windows
installers.

It distinguishes standalone installer bundles from MSI payloads owned by an
SDK, Visual Studio, or another installer. Shared and Visual Studio-managed
payloads remain visible in the inventory but are deliberately read-only.

## Requirements

- Windows
- Windows PowerShell 5.1 or PowerShell 7+
- Internet access to Microsoft's official .NET release metadata and downloads
- Administrator approval when an installer needs to modify the machine

Daily builds and archive-based installations are not currently supported.

## Installation

After the first release is published, install from PowerShell Gallery with
PSResourceGet:

```powershell
Install-PSResource DotNetSteward
```

PowerShellGet is also supported:

```powershell
Install-Module DotNetSteward
```

To import directly from a source checkout:

```powershell
Import-Module .\DotNetSteward.psd1
```

## Inventory

```powershell
Get-DotNetInstallation
Get-DotNetInstallation -ProductType Sdk
Get-DotNetInstallation -ProductType Runtime, AspNetCoreRuntime
Get-DotNetInstallation -Architecture x64
Get-DotNetInstallation | Where-Object ManagedByVisualStudio
```

Inventory records include the product type, semantic version, payload
architecture, management source, owners, and whether DotNetSteward can update
or uninstall the installation.

Supported product types are:

- `Sdk`
- `Runtime`
- `AspNetCoreRuntime`
- `WindowsDesktopRuntime`

## Update SDKs

Run interactively, with every available update selected by default:

```powershell
Update-DotNetSdk
```

Run non-interactively:

```powershell
Update-DotNetSdk -UpdateAll
Update-DotNetSdk -VersionBand 8.0.4xx, 9.0 -UpdateScope Patch
Update-DotNetSdk -UpdateAll -UpdateScope Major -IncludePreview
```

SDK update scopes are `Patch`, `FeatureBand`, and `Major`.
`FeatureBand` is the default.

## Update runtimes

```powershell
Update-DotNetRuntime
Update-DotNetRuntime -UpdateAll
Update-DotNetRuntime -ProductType WindowsDesktopRuntime -UpdateAll
Update-DotNetRuntime -VersionBand 8.0 -Architecture x64 -UpdateScope Major
```

Runtime update scopes are `Patch` and `Major`. Only standalone runtime EXE
bundles are updateable; shared MSI payloads are never modified directly.

## Preview releases

An installed prerelease can advance through later previews, release candidates,
and stable releases without an additional switch. Updating a stable
installation to a preview requires `-IncludePreview`.

## Download and installation safety

DotNetSteward:

1. Resolves releases through Microsoft's official releases index.
2. Downloads selected installers in parallel using BITS.
3. Verifies each SHA-512 hash from the release metadata.
4. Verifies the Authenticode signer and expected Microsoft certificate chain.
5. Runs installers sequentially from lowest to highest target version.
6. Uses unattended installer arguments by default while allowing Windows to
   request UAC elevation.

Use `-InteractiveInstaller` to display each installer's UI.

## Repository layout

```text
Private/                       Internal discovery, planning, and installer helpers
Public/                        Exported PowerShell commands
tests/Verify.ps1               Parser, module, behavior, and metadata verification
DotNetSteward.Format.ps1xml    Default installation table view
DotNetSteward.psd1             Module manifest
DotNetSteward.psm1             Module loader and exports
```

Run verification locally with either supported PowerShell edition:

```powershell
.\tests\Verify.ps1
```

Release versioning, optional signing, provenance, and repository configuration
are documented in [docs/release-and-provenance.md](docs/release-and-provenance.md).

## License

DotNetSteward is licensed under the [MIT License](LICENSE).
