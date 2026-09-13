# Release, signing, and provenance

DotNetSteward uses a manually initiated, tag-based release process. The normal
operator experience is to run **Start Release** from `main`; the workflows
calculate the version, update the module manifest, validate the source, create
the release tag, and dispatch the finalizer.

The finalizer optionally signs the PowerShell files, creates release packages,
attests them, uploads and verifies a draft GitHub Release, publishes that
release, and publishes the exact same `.nupkg` to PowerShell Gallery.

## Release phases

Three release phases are supported:

- **Pre**: early prereleases such as `0.2.0-pre1`
- **RC**: release candidates such as `0.2.0-rc1`
- **RTM**: stable releases such as `0.2.0`

PowerShell Gallery prerelease labels cannot contain dots, so DotNetSteward uses
`pre1` and `rc1` rather than the template repository's `pre.1.rel` and
`rc.1.rel` labels.

With `version_bump=auto`, phase progression behaves as follows:

| Current release | Requested phase | Result |
|---|---|---|
| `0.1.0` | `pre` | `0.1.1-pre1` |
| `0.1.1-pre1` | `pre` | `0.1.1-pre2` |
| `0.1.1-pre2` | `rc` | `0.1.1-rc1` |
| `0.1.1-rc1` | `rtm` | `0.1.1` |
| `0.1.1` | `rtm` | `0.1.2` |

The last row uses the configured default version bump. An explicit `patch`,
`minor`, or `major` workflow input always starts a new base version in the
requested phase.

## Workflow split

- `verify.yml` validates every pull request and push to `main` using PowerShell
  7 and Windows PowerShell 5.1.
- `start-release.yml` is **Start Release**, the normal manual entry point. It
  calculates the next version from existing GitHub Releases, updates and
  validates the module manifest, pushes the version commit to `main`, creates
  an annotated immutable tag, and dispatches the finalizer on that tag.
- `release.yml` is **Finalize Release**. It validates the tag and source commit,
  optionally signs the staged module, builds and verifies release artifacts,
  creates attestations and the GitHub Release, and publishes the same `.nupkg`
  to PowerShell Gallery.

Start and finalization share a concurrency group so only one release can
advance at a time.

## Required repository setup

### Production environment

Create a GitHub Actions environment named `production`. Both release workflows
use this environment.

Recommended settings:

- Add required reviewers so releases require explicit approval.
- Enable **Prevent self-review** when another reviewer is available.
- Restrict deployments to `main` and tags matching `v*`.
- Disable administrator bypass if releases must always pass the approval gate.

The **Start Release** workflow pushes its generated module-version commit
directly to `main`. If `main` is protected by a branch ruleset, allow
`github-actions[bot]` to bypass only the pull-request requirement, or use a
dedicated release GitHub App with equivalent narrowly scoped permission.

Add this required environment secret:

- `PSGALLERY_API_KEY`: API key belonging to the PowerShell Gallery account that
  owns `DotNetSteward`.

The start workflow checks for this secret before creating a release commit or
tag.

### Repository variables

The workflow supports these optional repository or environment variables:

- `DEFAULT_VERSION_BUMP`: `patch`, `minor`, or `major`; defaults to `patch`.
- `DEFAULT_RELEASE_PHASE`: `pre`, `rc`, or `rtm`; defaults to `rtm`.

With the defaults configured as `patch` and `rtm`, running **Start Release**
without changing its inputs publishes the next patch release. Workflow inputs
can override either decision for an individual release.

## Optional Azure Artifact Signing

Authenticode signing is enabled only when all of these `production` environment
secrets are present:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `AZURE_SIGNING_ENDPOINT`
- `AZURE_SIGNING_ACCOUNT`
- `AZURE_CERT_PROFILE`

If none are present, the release remains unsigned and relies on SHA-256
checksums and GitHub artifact attestations. A partial configuration fails
closed so a missing or renamed secret cannot silently produce an unsigned
release.

The Azure identity should use workload identity federation and have the
**Artifact Signing Certificate Profile Signer** role for the configured
certificate profile.

When signing is enabled, every staged `.ps1`, `.psm1`, `.psd1`, and `.ps1xml`
file is signed and then verified with `Get-AuthenticodeSignature` before
packaging.

## Release artifacts

Each GitHub Release contains:

- `DotNetSteward.<version>.nupkg`
- `DotNetSteward-<version>.zip`
- `checksums.txt`
- `release-metadata.json`
- `attestations.jsonl`

`release-metadata.json` binds the package version and hashes to the tagged
source commit and records whether Authenticode signing was enabled.

The release workflow uses `Compress-PSResource` to create the NuGet package and
publishes that exact file to PowerShell Gallery using `Publish-PSResource`.

GitHub attestations can be verified with:

```powershell
gh attestation verify .\DotNetSteward.0.1.0.nupkg `
    --repo DamianEdwards/dotnet-steward
```

## Cutting a release

1. Ensure the desired source commit is on `main` and the Verify workflow passed.
2. Open **Actions**, select **Start Release**, and choose **Run workflow** on
   `main`.
3. Keep `version_bump` set to `auto` to follow the current phase naturally, or
   explicitly select `patch`, `minor`, or `major`.
4. Keep `phase` set to `default` to use `DEFAULT_RELEASE_PHASE`, or select
   `pre`, `rc`, or `rtm`.
5. Approve the `production` environment deployment if required.

No manual manifest edit, tag, GitHub Release, package creation, or Gallery
publication is required.

## Failure recovery

GitHub Releases are treated as immutable:

- The finalizer never deletes or overwrites an existing published release.
- New artifacts are uploaded to a draft release, downloaded, and verified
  before the draft becomes public.
- An incomplete draft left by a failed attempt is deleted and rebuilt on rerun;
  published releases are never deleted or modified.
- If a GitHub Release already exists, a rerun downloads and verifies its
  checksums and GitHub attestations before checking or retrying PowerShell
  Gallery publication.
- If **Start Release** creates the tag but cannot dispatch the finalizer, run
  **Finalize Release** manually on that tag using the version and source commit
  shown in the Start Release summary.
- Never move or recreate a published release tag.

For additional protection, configure a tag ruleset for `v*` that blocks tag
updates and deletions while allowing new tags to be created by GitHub Actions.
