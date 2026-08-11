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

## Quick start (consumer projects)

Copy `download-dependencies.ps1` into your plugin repo (beside where you want
`rust-dependencies.json`). Then run:

```powershell
./download-dependencies.ps1
```

The script downloads the **latest** GitHub release zip, verifies it against the
asset's GitHub SHA-256 digest, and caches it in a **user-level** folder shared by
all projects:

- Windows: `%LOCALAPPDATA%\rust-dependencies\toolkit\<version>\`
- Linux/macOS: `${XDG_CACHE_HOME:-~/.cache}/rust-dependencies/toolkit/<version>/`

Override with `RD_TOOLKIT_CACHE` if needed. Then it prompts for:

1. which orchestration script to run (`rust`, `rust+oxide`, …)
2. whether to publicize after download (`y`/`n`)
3. server platform (`Windows` / `Linux` / `All`, or `1` / `2` / `3`)

Project manifests live next to the script (not inside the cache):

- `rust-dependencies.json` — production (auto-created from the toolkit example if missing)
- optional `rust-staging-dependencies.json` — staging / Rider second target

Pin or skip prompts for CI (pass every prompted value; use `-Publicize:$false`
when you do not want publicizing):

```powershell
./download-dependencies.ps1 -Version 1.2.3 -Script rust+oxide -ServerPlatform Windows -Publicize:$false
./download-dependencies.ps1 -Script rust -ServerPlatform Linux -Publicize
```

## Quick start (this repository / local toolkit)

Running `./download-dependencies.ps1` from this checkout uses the local toolkit
and skips the GitHub download (it detects `scripts/utility/Invoke-RustDependencies.ps1`
beside the script). You still get the interactive prompts unless you pass
`-Script` / `-ServerPlatform` / `-Publicize`.

Focused wrappers also work directly. If `rust-dependencies.json` is missing, it
is created from `examples/rust-dependencies.example.json`.

```powershell
./download-dependencies.ps1 -Script all -ServerPlatform Windows -Publicize:$false
./scripts/rust+oxide.ps1
./scripts/rust.ps1 -ServerPlatform Linux
```

`-ServerPlatform` accepts `Windows`, `Linux`, or `All` (both, in that order) and
defaults to the host OS. With `All` and `-ClearOutput`, the output directory is
cleared once before Windows, then Linux is filled without a second wipe.
`-Framework` accepts `Oxide`, `Carbon`, or `Both` and defaults to `Both`; it is
independent from both host and server operating systems.
Production scripts use the Steam public branch, Oxide production asset, and
Carbon `production_build`. Staging scripts select the Steam staging branch and
Carbon `rustbeta_staging_build` with its exact Windows/Linux `Debug` assets.
Oxide staging uses the platform-specific artifacts under
`https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/`.

Every top-level orchestration script (`rust.ps1`, `rust+oxide.ps1`, …) clears
the contents of the manifest's configured `outputDirectory` before it starts
(the directory itself is kept). Focused Rust/Oxide/Carbon downloads clear only
the framework roots they rebuild (for example `windows/oxide/`) and leave the
sibling framework root intact. Public/private/NuGet-only wrappers overlay DLLs
without clearing. Stale packages removed from the manifest remain until the next
framework-root rebuild or a top-level / `-ClearOutput` run.

## Entrypoints

Focused downloads:

- `scripts/rust/download.ps1` and `scripts/rust/staging.ps1`
- `scripts/oxide/download.ps1` and `scripts/oxide/staging.ps1`
- `scripts/carbon/download.ps1` and `scripts/carbon/staging.ps1`
- `scripts/utility/public-dlls.ps1` and `scripts/utility/private-dlls.ps1`
- `scripts/utility/publicize.ps1` (publicize already-downloaded framework roots)

Clean orchestration:

- `scripts/all.ps1` / `scripts/all-staging.ps1`
- `scripts/rust+oxide.ps1` / `scripts/rust-staging+oxide.ps1`
- `scripts/rust+carbon.ps1` / `scripts/rust-staging+carbon.ps1`
- `scripts/rust.ps1` / `scripts/rust-staging.ps1`

Only these eight frequently used orchestration wrappers live directly under
`scripts/`. `rust` / `rust-staging` clear output and overlay Rust Steam DLLs into
both framework roots.
The single automation/bootstrap entrypoint lives under `scripts/utility/`:

```powershell
./scripts/utility/Invoke-RustDependencies.ps1 `
  -Provider Rust,Oxide,Public,NuGet -Framework Oxide `
  -Channel Production -ClearOutput
```

Opt into in-place publicizing with `-Publicize` (default off):

```powershell
./scripts/rust+oxide.ps1 -Publicize
./scripts/utility/publicize.ps1 -Framework Oxide
```

The module can also be imported directly (module API still requires an explicit
manifest path):

```powershell
Import-Module ./module/RustDependencies.psd1
Invoke-RustDependencies -ManifestPath ./rust-dependencies.json `
  -Provider Rust,Carbon,Public,Private,NuGet -Framework Carbon
```

All toolkit scripts support `-WhatIf`, which prints the planned platform, channel,
framework, providers, output path, clear/publicize flags, and publicizer
destinations without downloading. Use `-Verbose` for DepotDownloader and
download progress. Errors are terminating, temporary directories are removed in
`finally`, and toolkit scripts never call `Read-Host`. The consumer
`download-dependencies.ps1` is the only interactive entrypoint; pass `-Script`,
`-ServerPlatform`, and `-Publicize` / `-Publicize:$false` to skip prompts.

## Manifest

Default files at the toolkit root (no `-ManifestPath` needed):

| File | Used by |
|------|---------|
| `rust-dependencies.json` | Production scripts, and staging scripts when no staging file exists |
| `rust-staging-dependencies.json` | Staging scripts only, when present |

**Scenario 1:** only `rust-dependencies.json` — every script uses it (staging
wrappers still select the Staging channel/assets).

**Scenario 2 (Rider dual target):** also copy
`examples/rust-staging-dependencies.example.json` to
`rust-staging-dependencies.json` with a separate `outputDirectory` (default
example: `./dependencies-staging`). Production scripts write one tree; staging
scripts write the other. Override anytime with `-ManifestPath`.

Start from `examples/rust-dependencies.example.json`. `outputDirectory` is
resolved relative to the manifest (or as an absolute path). Put the DLLs
anywhere you want — including outside the project — by setting that path.

```json
{
  "outputDirectory": "../src/dependencies"
}
```

Filesystem roots, home directories, shallow system paths, and paths that would
contain the manifest itself are still rejected.

Native/non-managed package junk (`*.so`/`*.dylib`/`*.a`/`*.lib`/`*.exe`,
`*/native/*`, RID folders) is always excluded by the toolkit.

The schema supports:

- `outputDirectory`;
- top-level `publicReleases`, `privateReleases`, and `githubNuget` arrays;
- optional `deleteDlls` file-name list removed from each written framework root
  after download and before publicize (avoids Rider/reference conflicts and
  skips publicizing those DLLs, e.g. duplicate `Newtonsoft.Json.dll`);
- GitHub NuGet v3 package sources, exact or `latest` versions, and prerelease policy;
- optional framework filtering on release and NuGet entries.

Steam (Rust dedicated), Oxide, and Carbon download targets are hardcoded in the
module. Configurable collections sit at the top level:

```json
{
  "publicReleases": [],
  "privateReleases": [],
  "githubNuget": [],
  "deleteDlls": [
    "UnityEngine.ARModule.dll",
    "UnityEngine.NVIDIAModule.dll",
    "Microsoft.Bcl.AsyncInterfaces.dll",
    "Microsoft.Win32.Registry.dll",
    "System.Text.Encodings.Web.dll",
    "System.Numerics.Vectors.dll",
    "Newtonsoft.Json.dll"
  ]
}
```

`deleteDlls` entries are plain file names (no paths). Missing files are ignored.

Providers overlay into a flat tree in order: Rust → Oxide or Carbon →
publicReleases → privateReleases → NuGet. Same filenames overwrite earlier
copies. Oxide and Carbon each get their own root under the platform folder.

Rust depot downloads are selective. The toolkit writes a UTF-8-no-BOM
DepotDownloader file list and passes it with `-filelist`; the fixed rule is:

```text
regex:RustDedicated_Data/Managed/.*\.dll
```

DepotDownloader regex matching is unanchored, so this also matches a
`RustDedicated_Data/Managed` directory beneath a Linux depot prefix without
requesting the rest of the depot.

After download, the toolkit selects only a real
`RustDedicated_Data/Managed` directory that directly contains DLL files.
DepotDownloader bookkeeping beneath `.DepotDownloader` is always ignored.
Selection is sorted and deterministic; zero candidates or multiple real
candidates produce a terminating error instead of copying from an arbitrary
directory.

DepotDownloader is always fetched from `SteamRE/DepotDownloader` for the host
(`windows-x64` or `linux-x64`). Self-contained archives are supported directly:

- Windows: `DepotDownloader.exe`
- Linux: `DepotDownloader` (the toolkit applies `chmod u+x` after ZIP extraction)
- Framework-dependent fallback: `DepotDownloader.dll`, invoked through `dotnet`

`dotnet` is required only for the DLL form. Archives missing all supported host
files fail with an actionable error.

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
for both frameworks is downloaded once and overlaid into both framework roots.
Missing `frameworks` means a shared dependency and is overlaid into every
selected framework root (`oxide` and/or `carbon`).

Oxide and Carbon assets are also hardcoded (production GitHub releases; Oxide
staging from `https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/`).
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

`-Publicize` and `scripts/utility/publicize.ps1` rewrite selected assemblies in
each merged framework root with Mono.Cecil rules that mirror Oxide and Carbon.
Publicized DLLs are written over the flat-root originals (same filenames); other
DLLs in the root are left unchanged.

`-Framework Oxide` runs Oxide rules only, `Carbon` runs Carbon rules only, and
`Both` publicizes both roots. Carbon mode uses Carbon’s assembly allowlist,
member-ignore regexes (`HiddenValue*`, `Pool`), skips event backing fields, and
sets `IsNotSerialized` when promoting non-`SerializeField` fields. Oxide mode
uses Oxide’s assembly opt-out prefixes and skips compiler-generated / extension
members. Neither mode strips `InternalsVisibleTo` or applies Carbon’s bootstrap
patches.

## Output layout

DLLs are flattened by filename under platform + framework:

```text
dependencies/
  windows/
    oxide/                 # Rust → Oxide → releases/NuGet → optional publicize overlay
    carbon/
  linux/
    oxide/
    carbon/
```

Reference e.g. `dependencies/windows/oxide/`. Native compile artifacts are
excluded by default.

## Release consumption

Tags named `v*` produce `rust-dependencies-<version>.zip`. GitHub attaches an
immutable SHA-256 digest to that asset (shown in the Releases UI and returned
as `digest` on the Releases API).

Prefer the root `download-dependencies.ps1` in consumer projects: it downloads
the zip, verifies it against that digest, caches under the shared user toolkit
folder, and runs the selected orchestration script. Pin with `-Version` when you
need a fixed toolkit. When the script runs inside a full toolkit checkout, it
uses that tree and skips downloading.

The archive preserves the repository layout beneath a single
`rust-dependencies-<version>/` root (including `download-dependencies.ps1` at
that root). The eight orchestration wrappers are directly in `scripts/`; focused
wrappers are grouped under `scripts/rust/`, `scripts/oxide/`, `scripts/carbon/`,
and `scripts/utility/`; the module is in `module/`; and examples are in
`examples/`.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `Unsafe outputDirectory` | Choose a deeper path; roots, `$HOME`, shallow paths, and the manifest directory are blocked |
| `Multiple … Managed directories` / ambiguous selection | Archive or depot layout changed; the toolkit refuses to guess |
| `GitHub authentication required` | Set `GH_TOKEN` or `GITHUB_TOKEN`, or authenticate `gh` |
| `RdPublicizer was not found` | Use a release archive, or install .NET SDK and keep `tools/RdPublicizer` |
| `dotnet is required to run DepotDownloader DLL` | Install .NET so the downloaded DepotDownloader DLL can run |
| Empty publicizer output / no assemblies selected | Carbon allowlist matched nothing under `<platform>/<framework>/` |
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
