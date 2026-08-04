# rust-dependencies

A PowerShell 7 toolkit for assembling managed compile-time dependencies for Rust
server plugins. It runs on Windows and Linux, and the server target is selected
independently from the host.

## Quick start

```powershell
Copy-Item rust-dependencies.example.json rust-dependencies.json
./all-oxide-dependencies-download.ps1 `
  -ManifestPath ./rust-dependencies.json `
  -ServerPlatform Linux
```

`-ServerPlatform` accepts `Windows` or `Linux` and defaults to the host OS.
Production scripts use the Steam public branch, Oxide production asset, and
Carbon `production_build`. Staging scripts select the Steam staging branch and
Carbon `rustbeta_staging_build` with its exact Windows/Linux `Debug` assets.
Oxide staging uses the platform-specific artifacts under
`https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/`.

Every `all-*` script deletes and recreates only the manifest's configured
`outputDirectory` before it starts. Focused scripts update their own
source/platform folder and never clear unrelated output.

## Entrypoints

Focused downloads:

- `rust-dependencies-download.ps1` and `rust-staging-dependencies-download.ps1`
- `oxide-dependencies-download.ps1` and `oxide-staging-dependencies-download.ps1`
- `carbon-dependencies-download.ps1` and `carbon-staging-dependencies-download.ps1`
- `public-dlls-download.ps1` and `private-dlls-download.ps1`

Clean orchestration:

- `all-dependencies-download.ps1` / `all-staging-dependencies-download.ps1`
- `all-oxide-dependencies-download.ps1` / `all-oxide-staging-dependencies-download.ps1`
- `all-carbon-dependencies-download.ps1` / `all-carbon-staging-dependencies-download.ps1`

For automation or bootstrap consumers, use the stable root entrypoint:

```powershell
./Invoke-RustDependencies.ps1 -ManifestPath ./rust-dependencies.json `
  -Provider Rust,Oxide,Public,NuGet -Channel Production -ClearOutput
```

The module can also be imported directly:

```powershell
Import-Module ./RustDependencies.psd1
Invoke-RustDependencies -ManifestPath ./rust-dependencies.json -Provider Carbon
```

All scripts support `-WhatIf`. Errors are terminating, temporary directories
are removed in `finally`, and scripts never call `Read-Host`.

## Manifest

Start with `rust-dependencies.example.json`. Paths are relative to the manifest.
`repositoryRoot` establishes the deletion safety boundary, and
`outputDirectory` must resolve beneath it. For a consumer layout with a
manifest at `scripts/dependencies.json`, use:

```json
{
  "repositoryRoot": "..",
  "outputDirectory": "../src/dependencies",
  "allowOutputOutsideRepository": false
}
```

Set `allowOutputOutsideRepository` to the JSON boolean `true` only for a
deliberate external output location. Filesystem roots, home directories,
repository roots, paths containing the manifest, and reparse-point escapes are
still rejected.

The schema supports:

- repository boundary, output directory, external-output opt-in, and exclusion globs;
- Steam app, target depots, branches, and optional DepotDownloader descriptor;
- per-channel/per-target Oxide and Carbon release descriptors;
- public and private GitHub release arrays;
- GitHub NuGet v3 package sources, exact or `latest` versions, and prerelease policy;
- optional target-platform mapping metadata.

A release descriptor is either:

```json
{ "url": "https://example.invalid/assets/dependencies.zip" }
```

or:

```json
{
  "repo": "owner/repository",
  "tag": "latest",
  "asset": "dependencies.zip"
}
```

`assetPattern` may replace `asset` and is a PowerShell regular expression.
Release collections accept `.zip`, `.tar.gz`, `.tgz`, `.nupkg`, and direct
`.dll` assets. A direct DLL is copied without extraction. A
private release entry wraps a descriptor with a stable output name:

```json
{
  "name": "MyPrivateApi",
  "release": {
    "repo": "owner/private-repository",
    "tag": "latest",
    "asset": "MyPrivateApi.zip"
  }
}
```

Oxide staging defaults can be overridden with target-specific descriptors.
URLs whose path does not end in the archive name require `name`:

```json
{
  "providers": {
    "oxide": {
      "assets": {
        "Staging": {
          "Windows": {
            "url": "https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust.zip",
            "name": "Oxide.Rust.zip"
          },
          "Linux": {
            "url": "https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust-linux.zip",
            "name": "Oxide.Rust-linux.zip"
          }
        }
      }
    }
  }
}
```

As of this toolkit release, `https://umod.org/games/rust/download/develop`
redirects to the latest Linux production GitHub asset, and the Oxide GitHub
repository exposes no staging/prerelease release. It is therefore not used as
a staging default.

A GitHub NuGet entry uses the feed's v3 index:

```json
{
  "name": "My.Package",
  "source": "https://nuget.pkg.github.com/OWNER/index.json",
  "version": "latest",
  "includePrerelease": false
}
```

Authentication is read from `GH_TOKEN`, then `GITHUB_TOKEN`, then an existing
authenticated `gh` session. `gh` is not required for public downloads and is
only queried when private or GitHub NuGet authentication is required. Tokens are never
prompted for or persisted.

## Output layout

Managed files are isolated by source and server target:

```text
dependencies/
  rust/windows/managed/
  oxide/linux/managed/
  carbon/windows/managed/
  publicReleases/linux/Example/
  privateReleases/windows/Example/
  nuget/linux/Example.Package/
```

Useful relative paths are preserved. Rust and Oxide collect managed DLLs;
Carbon recursively collects `carbon/managed/**/*.dll`, including
`carbon/managed/lib`. Native compile artifacts are excluded by default.

## Release consumption

Tags named `v*` produce:

- `rust-dependencies-<version>.zip`
- `rust-dependencies-<version>.zip.sha256`

The archive has a single `rust-dependencies-<version>/` root containing the
entrypoint, module, wrappers, example manifest, license, and documentation.
A bootstrap should download both assets, verify SHA-256, extract to a
versioned cache directory, and invoke `Invoke-RustDependencies.ps1`. Pin a tag
in production; do not bootstrap from a mutable branch.

## Testing

```powershell
./tests/smoke.ps1
Invoke-Pester ./tests
```

The smoke suite has no dependencies. Pester tests mock provider/network-facing
operations and cover manifest/path validation, platform selection, cleanup,
archive dispatch, orchestration, and failure cleanup.
