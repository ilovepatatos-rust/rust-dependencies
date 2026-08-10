# Changelog

## Unreleased

### Breaking

- Entrypoints moved from repository-root `*-dependencies-download.ps1` names into
  `scripts/`, with focused wrappers under `scripts/rust/`, `scripts/oxide/`,
  `scripts/carbon/`, and `scripts/utility/`.
- Module files live under `module/`; the example manifest lives under `examples/`.
- Manifest `providers` section removed. Steam/Oxide/Carbon targets are hardcoded;
  `publicReleases`, `privateReleases`, and `githubNuget` are top-level arrays.
- Output layout is a flat overlay under `<platform>/<oxide|carbon>/` (Rust →
  framework → releases/NuGet by filename). Separate provider trees and `shared`
  package folders are gone. `-Publicize` overlays publicized assemblies onto
  those same flat roots (no `publicized/` subfolder).

### Added

- `download-dependencies.ps1` (renamed from `Bootstrap-RustDependencies.ps1`):
  consumer entrypoint that downloads/verifies the latest toolkit release,
  caches it under `.rust-dependencies-toolkit/`, prompts for script / publicize /
  server platform, and runs against project manifests. Skips download when run
  from a full toolkit checkout. Use `-Script` / `-ServerPlatform` / `-Publicize`
  / `-Version` for CI.
- Channel-aware default manifests: `rust-dependencies.json` for production,
  optional `rust-staging-dependencies.json` for staging (with
  `examples/rust-staging-dependencies.example.json`); `-ManifestPath` optional
  on wrappers.
- Opt-in `-Publicize` switch and `scripts/utility/publicize.ps1` using
  `tools/RdPublicizer` (Mono.Cecil) with Oxide and Carbon visibility rules.
- Manifest `deleteDlls` array removes named DLLs from framework roots after
  download and before publicize (Rider conflict avoidance).
- `-ServerPlatform All` downloads Windows then Linux into both platform folders.
- Focused framework-root cleanup before rewrite when Rust/Oxide/Carbon run.
- Richer `-WhatIf` planning output and `-Verbose` DepotDownloader logging.
- Release packaging stamps `ModuleVersion` from the git tag and ships
  self-contained `RdPublicizer` binaries for `win-x64` and `linux-x64`.

### Removed

- Windows `.cmd` double-click launchers for bootstrap and `scripts/all-*`.

### Fixed

- Oxide and Carbon managed-directory selection now rejects zero or multiple
  candidates instead of taking the first match.
