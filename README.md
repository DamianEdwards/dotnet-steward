# DotNetSteward

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

## Install

Install DotNetSteward from the PowerShell Gallery for the current user:

```powershell
Install-PSResource DotNetSteward -Scope CurrentUser -TrustRepository
```

PowerShell automatically imports the module when you use one of its commands.
To update an existing installation:

```powershell
Update-PSResource DotNetSteward
```

When developing or testing the module from a repository checkout, import the
manifest directly instead:

```powershell
Import-Module .\DotNetSteward.psd1
```

## Not using Windows?

DotNetSteward manages Windows installer-based .NET installations and does not
run on macOS or Linux. Use [`dotnetup`](https://aka.ms/dotnetup) instead for
cross-platform, user-level installation and management of .NET SDKs and
runtimes.

Install `dotnetup` on macOS or Linux:

```bash
curl -fsSL https://aka.ms/dotnetup/get-dotnetup.sh | bash
```

Then follow the printed `PATH` instructions, open a new terminal, and run:

```text
dotnetup init
```

The interactive setup lets you select a stable, LTS, preview, major-version,
feature-band, or exact-version SDK channel and choose how the managed .NET
installation is exposed to your shell.

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

## License

DotNetSteward is licensed under the [MIT License](LICENSE).
