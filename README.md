# rust-dependencies

A PowerShell 7 toolkit for assembling managed compile-time dependencies for Rust
server plugins. It runs on Windows and Linux, and the server target is selected
independently from the host.

## Prerequisites

- PowerShell 7 on Windows or Linux
- Network access for Steam/GitHub/Oxide/Carbon downloads
- `tar` on Linux when extracting `.tar.gz` / `.tgz` assets
- `dotnet` only when running a framework-dependent DepotDownloader `.dll`, or
  when building `tools/RdPublicizer` from source
- `gh` only as a fallback for private GitHub / GitHub NuGet auth when
  `GH_TOKEN` / `GITHUB_TOKEN` are unset

Released archives ship self-contained `RdPublicizer` binaries for `win-x64` and
`linux-x64`. The git tag (`v1.2.3`) is the source of truth for the toolkit
version; `ModuleVersion` in the release archive matches that tag.

## Quick start

```powershell
Copy-Item ./examples/rust-dependencies.example.json ./rust-dependencies.json
./scripts/all-oxide.ps1 `
  -ManifestPath ./rust-dependencies.json `
  -ServerPlatform Linux
```

`-ServerPlatform` accepts `Windows` or `Linux` and defaults to the host OS.
`-Framework` accepts `Oxide`, `Carbon`, or `Both` and defaults to `Both`; it is
independent from both host and server operating systems.
Production scripts use the Steam public branch, Oxide production asset, and
Carbon `production_build`. Staging scripts select the Steam staging branch and
Carbon `rustbeta_staging_build` with its exact Windows/Linux `Debug` assets.
Oxide staging uses the platform-specific artifacts under
`https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/`.

Every `all-*` script deletes and recreates only the manifest's configured
`outputDirectory` before it starts. Focused scripts clear only the provider
subtree they are about to write (for example `rust/<platform>/`,
`oxide/<platform>/`, or a named public/private/NuGet folder) and leave unrelated
output intact. Packages removed from the manifest remain until the next
`all-*` / `-ClearOutput` run.

## Entrypoints

Focused downloads:

- `scripts/rust/download.ps1` and `scripts/rust/staging.ps1`
- `scripts/oxide/download.ps1` and `scripts/oxide/staging.ps1`
- `scripts/carbon/download.ps1` and `scripts/carbon/staging.ps1`
- `scripts/utility/public-dlls.ps1` and `scripts/utility/private-dlls.ps1`
- `scripts/utility/publicize.ps1` (publicize already-downloaded Rust managed DLLs)

Clean orchestration:

- `scripts/all.ps1` / `scripts/all-staging.ps1`
- `scripts/all-oxide.ps1` / `scripts/all-oxide-staging.ps1`
- `scripts/all-carbon.ps1` / `scripts/all-carbon-staging.ps1`

Only these six frequently used `all-*` wrappers live directly under `scripts/`.
The single automation/bootstrap entrypoint lives under `scripts/utility/`:

```powershell
./scripts/utility/Invoke-RustDependencies.ps1 -ManifestPath ./rust-dependencies.json `
  -Provider Rust,Oxide,Public,NuGet -Framework Oxide `
  -Channel Production -ClearOutput
```

Opt into publicizing Rust managed assemblies with `-Publicize` (default off):

```powershell
./scripts/all-oxide.ps1 -ManifestPath ./rust-dependencies.json -Publicize
./scripts/utility/publicize.ps1 -ManifestPath ./rust-dependencies.json -Framework Oxide
```

The module can also be imported directly:

```powershell
Import-Module ./module/RustDependencies.psd1
Invoke-RustDependencies -ManifestPath ./rust-dependencies.json `
  -Provider Rust,Carbon,Public,Private,NuGet -Framework Carbon
```

All scripts support `-WhatIf`, which prints the planned platform, channel,
framework, providers, output path, clear/publicize flags, and publicizer
destinations without downloading. Use `-Verbose` for DepotDownloader and
download progress. Errors are terminating, temporary directories are removed in
`finally`, and scripts never call `Read-Host`.

## Manifest

Start with `examples/rust-dependencies.example.json`. Paths are relative to the manifest.
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
- Steam app, target depots, branches, selective file list, and optional DepotDownloader descriptor;
- per-channel/per-target Oxide and Carbon release descriptors;
- public and private GitHub release arrays;
- GitHub NuGet v3 package sources, exact or `latest` versions, and prerelease policy;
- optional framework filtering on release and NuGet entries;
- optional target-platform mapping metadata.

Rust depot downloads are selective by default. The toolkit writes a
UTF-8-no-BOM DepotDownloader file list and passes it with `-filelist`; the
single default rule is:

```text
regex:RustDedicated_Data/Managed/.*\.dll
```

DepotDownloader regex matching is unanchored, so this also matches a
`RustDedicated_Data/Managed` directory beneath a Linux depot prefix without
requesting the rest of the depot. Override it only when additional compile-time
files are required:

```json
{
  "providers": {
    "steam": {
      "fileList": [
        "regex:RustDedicated_Data/Managed/.*\\.dll",
        "RustDedicated_Data/SomeAdditionalAssembly.dll"
      ]
    }
  }
}
```

`fileList` must be a non-empty JSON array of non-empty strings.

After download, the toolkit selects only a real
`RustDedicated_Data/Managed` directory that directly contains DLL files.
DepotDownloader bookkeeping beneath `.DepotDownloader` is always ignored.
Selection is sorted and deterministic; zero candidates or multiple real
candidates produce a terminating error instead of copying from an arbitrary
directory.

DepotDownloader acquisition remains host-specific (`windows-x64` or
`linux-x64`). Self-contained archives are supported directly:

- Windows: `DepotDownloader.exe`
- Linux: `DepotDownloader` (the toolkit applies `chmod u+x` after ZIP extraction)
- Framework-dependent fallback: `DepotDownloader.dll`, invoked through `dotnet`

`providers.steam.depotDownloaderPath` may point to the matching host executable
or a `.dll`. `dotnet` is required only for the DLL form. Unsupported paths and
archives missing all supported host files fail with an actionable error.

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
`.dll` assets. A direct DLL is copied without extraction. For top-level
collection entries, `name` is only the logical output-folder name; URL assets
always default to the URL basename:

```json
{
  "name": "Oxide.Ext.ConsoleExt",
  "url": "https://example.invalid/releases/Oxide.Ext.ConsoleExt.dll"
}
```

If a URL has no useful basename, or the downloaded filename must be overridden,
set `assetName`. Legacy `name` as a URL filename is recognized only inside a
nested `release` descriptor, where it cannot conflict with the collection
item's logical name:

```json
{
  "name": "LogicalOutputFolder",
  "release": {
    "url": "https://example.invalid/download",
    "assetName": "Actual.Asset.dll"
  }
}
```

A
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

`publicReleases`, `privateReleases`, and `githubNuget` entries may restrict
themselves to one or both extension frameworks:

```json
{
  "name": "Example.Carbon.Api",
  "url": "https://example.invalid/Example.Carbon.Api.dll",
  "frameworks": ["Carbon"]
}
```

Filtering happens before authentication or download. With `-Framework Carbon`,
an `["Oxide"]` entry is not fetched. With `-Framework Both`, an entry declared
for both frameworks is downloaded once and installed into both framework
folders. Missing `frameworks` means a framework-neutral dependency and is
installed once under `shared`.

Oxide staging defaults can be overridden with target-specific descriptors.
URLs whose path does not end in the archive name require `assetName`:

```json
{
  "providers": {
    "oxide": {
      "assets": {
        "Staging": {
          "Windows": {
            "url": "https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust.zip",
            "assetName": "Oxide.Rust.zip"
          },
          "Linux": {
            "url": "https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust-linux.zip",
            "assetName": "Oxide.Rust-linux.zip"
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

## Publicizer

`-Publicize` and `scripts/utility/publicize.ps1` rewrite **Rust managed** game
assemblies with Mono.Cecil rules that mirror Oxide and Carbon. Originals under
`rust/<platform>/managed/` are never mutated. Publicized copies are written to:

```text
rust/<platform>/publicized/oxide/
rust/<platform>/publicized/carbon/
```

`-Framework Oxide` runs Oxide rules only, `Carbon` runs Carbon rules only, and
`Both` produces both folders. Carbon mode uses Carbon’s assembly allowlist,
member-ignore regexes (`HiddenValue*`, `Pool`), skips event backing fields, and
sets `IsNotSerialized` when promoting non-`SerializeField` fields. Oxide mode
uses Oxide’s assembly opt-out prefixes and skips compiler-generated / extension
members. Neither mode strips `InternalsVisibleTo` or applies Carbon’s bootstrap
patches.

## Output layout

Managed files are isolated by source and server target:

```text
dependencies/
  rust/windows/managed/
  rust/windows/publicized/oxide/
  rust/windows/publicized/carbon/
  oxide/linux/managed/
  carbon/windows/managed/
  publicReleases/carbon/linux/Example/
  privateReleases/oxide/windows/Example/
  nuget/shared/linux/Example.Package/
```

Useful relative paths are preserved. Rust and Oxide collect managed DLLs;
Carbon recursively collects `carbon/managed/**/*.dll`, including
`carbon/managed/lib`. Framework-specific and shared provider folders prevent
same-named Oxide and Carbon assets from colliding. Native compile artifacts are
excluded by default.

## Release consumption

Tags named `v*` produce:

- `rust-dependencies-<version>.zip`
- `rust-dependencies-<version>.zip.sha256`

The archive preserves the repository layout beneath a single
`rust-dependencies-<version>/` root. The six `all-*` wrappers are directly in
`scripts/`; focused wrappers are grouped under `scripts/rust/`,
`scripts/oxide/`, `scripts/carbon/`, and `scripts/utility/`; the module is in
`module/`; and the example manifest is in `examples/`. A bootstrap should
download both assets, verify SHA-256, extract to a versioned cache directory,
and recursively locate the one `Invoke-RustDependencies.ps1` instead of
assuming it is at the extraction root:

```powershell
$entrypoint = Get-ChildItem $cacheDirectory -Recurse -File `
  -Filter Invoke-RustDependencies.ps1 |
  Select-Object -First 1
if (-not $entrypoint) { throw 'Invoke-RustDependencies.ps1 was not found.' }
& $entrypoint.FullName -ManifestPath $manifestPath -Provider Rust,Oxide
```

Pin a tag in production; do not bootstrap from a mutable branch.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `Unsafe outputDirectory` / outside repository | Fix `repositoryRoot` / `outputDirectory`, or set `allowOutputOutsideRepository` to JSON `true` only when intentional |
| `Multiple … Managed directories` / ambiguous selection | Archive or depot layout changed; the toolkit refuses to guess |
| `GitHub authentication required` | Set `GH_TOKEN` or `GITHUB_TOKEN`, or authenticate `gh` |
| `RdPublicizer was not found` | Use a release archive, or install .NET SDK and keep `tools/RdPublicizer` |
| `dotnet is required to run DepotDownloader DLL` | Install .NET, or configure a self-contained DepotDownloader path |
| Empty publicizer output / no assemblies selected | Carbon allowlist matched nothing under `rust/<platform>/managed` |
| Rate limits / failed downloads | Retry later; authenticated GitHub requests have higher limits |

## Testing

```powershell
./tests/smoke.ps1
Invoke-Pester ./tests
dotnet run --project ./tools/RdPublicizer -- --self-test
```

The smoke suite has no dependencies. Pester tests mock provider/network-facing
operations and cover manifest/path validation, platform selection, cleanup,
archive dispatch, orchestration, publicizer wiring, and failure cleanup.
