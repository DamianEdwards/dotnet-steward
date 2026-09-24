# DotNetSteward

[![Verify](https://github.com/DamianEdwards/dotnet-steward/actions/workflows/verify.yml/badge.svg)](https://github.com/DamianEdwards/dotnet-steward/actions/workflows/verify.yml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/DotNetSteward?label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/DotNetSteward)

DotNetSteward is a Windows PowerShell module for discovering, installing,
inventorying, and updating official Microsoft .NET SDK and runtime
installations managed by Windows installers.

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

Install DotNetSteward from the PowerShell Gallery for the current user:

```powershell
Install-PSResource DotNetSteward -Scope CurrentUser -TrustRepository
```

PowerShell automatically imports the module when you use one of its commands.
To update an existing installation:

```powershell
Update-PSResource DotNetSteward
```

PowerShellGet is also supported:

```powershell
Install-Module DotNetSteward -Scope CurrentUser
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
Get-DotNetInstallation -SkipSupportCheck
```

Inventory records include the product type, semantic version, payload
architecture, management source, owners, and whether DotNetSteward can update
or uninstall the installation.

The default table includes **EOL date** and **Days to EOL** columns before
**Status**. The date is the channel's end-of-support date, formatted as
`yyyy-MM-dd`. Days to EOL is the difference from the current local time, rounded
up to a whole integer: positive before EOL, zero on the EOL date, and negative
afterwards. Both columns are blank when the date is unavailable or the support
check was skipped.

The **Status** column is based on Microsoft's official
release metadata, with the same lifecycle and patch-status categories as
`dotnet sdk check`: `Up to date.`, `Patch <version> is available.`,
`.NET <channel> is going out of support soon.` (maintenance), or
`.NET <channel> is out of support.` Lifecycle warnings take precedence over
patch availability. SDK patches are compared within the installed feature band;
runtimes are compared within their major/minor channel. Preview versions use
the same comparison rules; `Up to date.` does not imply a preview is supported
for production.

Objects expose `SupportStatus`, `SupportPhase`, `Channel`, `EndOfSupportDate`,
and `LatestPatchVersion` for scripting. `Channel` is the catalog channel, which
can differ from an early SDK's major/minor version. `LatestPatchVersion` is
populated when checking patch availability, not for maintenance or end-of-life
channels. Status also applies to read-only and Visual Studio-managed records
without changing their ownership or updateability.

Status checks require network access. If metadata is unavailable or invalid,
the command warns and still returns local inventory with `Unknown` status for
affected records. Use `-SkipSupportCheck` for offline inventory; status is then
`Not checked`. Empty or fully filtered inventory does not trigger a lookup.

Supported product types are:

- `Sdk`
- `Runtime`
- `AspNetCoreRuntime`
- `WindowsDesktopRuntime`

## Find available releases

Search Microsoft's official release catalog for Windows installers:

```powershell
Find-DotNetSdk
Find-DotNetSdk -Channel 8.0
Find-DotNetSdk -VersionBand 8.0.4xx -AllVersions
Find-DotNetSdk -Channel 11.0 -IncludePreview
Find-DotNetSdk -Version 11.0.100-preview.7

Find-DotNetRuntime
Find-DotNetRuntime -ProductType WindowsDesktopRuntime -Channel 8.0
Find-DotNetRuntime -ProductType AspNetCoreRuntime -AllVersions
```

By default, the find commands return the latest stable release in every
matching channel for the native Windows architecture. Use `-AllVersions` for
the complete matching history, `-IncludePreview` to include prereleases in
channel or feature-band searches, and `-Architecture` to request x64, x86, or
Arm64 installers. Exact prerelease versions do not require
`-IncludePreview`.

## Install SDKs and runtimes

Fresh installs do not require an existing .NET installation:

```powershell
Install-DotNetSdk -Version 8.0.419
Install-DotNetSdk -Channel 8.0
Install-DotNetSdk -VersionBand 8.0.4xx
Install-DotNetSdk -Channel 11.0 -IncludePreview

Install-DotNetRuntime -Version 8.0.31
Install-DotNetRuntime -ProductType AspNetCoreRuntime -Channel 8.0
Install-DotNetRuntime -ProductType WindowsDesktopRuntime -Channel 11.0 -IncludePreview
```

`Install-DotNetRuntime` installs the base .NET Runtime unless `-ProductType`
is specified. Both install commands default to the native Windows architecture
and support installing multiple versions, channels, product types, or
architectures in one operation. Downloads run in parallel; installers run
sequentially from lowest to highest version.

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
3. Verifies each SHA-256 or SHA-512 hash declared by the release metadata.
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
