# Changelog

## Unreleased

### Breaking

- Entrypoints moved from repository-root `*-dependencies-download.ps1` names into
  `scripts/`, with focused wrappers under `scripts/rust/`, `scripts/oxide/`,
  `scripts/carbon/`, and `scripts/utility/`.
- Module files live under `module/`; the example manifest lives under `examples/`.

### Added

- Opt-in `-Publicize` switch and `scripts/utility/publicize.ps1` using
  `tools/RdPublicizer` (Mono.Cecil) with Oxide and Carbon visibility rules.
- Publicized output under `rust/<platform>/publicized/<oxide|carbon>/`.
- Focused provider subtree cleanup before rewrite.
- Richer `-WhatIf` planning output and `-Verbose` DepotDownloader logging.
- Release packaging stamps `ModuleVersion` from the git tag and ships
  self-contained `RdPublicizer` binaries for `win-x64` and `linux-x64`.

### Fixed

- Oxide and Carbon managed-directory selection now rejects zero or multiple
  candidates instead of taking the first match.
