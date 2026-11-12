# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-11-13

### Fixed
- Tests: the Korean `where` test sets `USERPROFILE` as well as `HOME`, so it passes in Windows CI.

## [0.2.1] - 2026-11-13

### Changed
- CI: print toolchain versions and failure diagnostics.

## [0.2.0] - 2026-11-12

### Added
- Korean messages: help, results and errors can be printed in English or Korean. Choose with `--lang en|ko` (before or after the command), `OLLAMA_CARRY_LANG`, or the usual `LC_ALL` / `LC_MESSAGES` / `LANG`; anything that is not Korean prints English.
- `CarryException` (and `TarFormatException`) have optional `code` and `params` fields and a `CarryException.coded` constructor, so errors can be translated; `message` stays English.
- `VerifyReport.toText` takes an optional `lang`; `exportModels`, `importBundle` and `runTour` take an optional `lang` for their progress lines.

### Changed
- On a Korean locale (`LANG`/`LC_ALL`/`LC_MESSAGES` starting with `ko`) human readable output is now Korean. Scripts that match the English text should set `OLLAMA_CARRY_LANG=en` or pass `--lang en`. JSON output, exit codes, command and option names, and the bundle format are unchanged.
- Bundles record the new tool version (`0.2.0`) in `carry.json`; the bundle format version is unchanged.

## [0.1.2] - 2026-11-11

### Fixed
- `<command> --help` and `-h` now print that command's usage and exit 0 instead of failing with "Could not find an option".

### Known limitations
- The error output for an unknown option does not include a `Usage:` line. The error path is intentionally unchanged in this release.

## [0.1.1] - 2026-11-10

### Changed
- README: replaced the comparison table with a short "when to use" section.

## [0.1.0] - 2026-11-10

### Added
- `where`, `list`, `export`, `import`, `verify`, `mock` and `tour` commands.
- Bundles that store shared blobs once, in a deterministic tar (ustar with PAX
  `path`/`size` records, so blobs above 8 GiB and long names work).
- `--split` into numbered parts (`512K`, `3.9G`, `fat32`) and a
  `sha256sum`-compatible `<bundle>.sha256` list of part checksums.
- Import that hashes every blob while unpacking into a staging folder, installs
  blobs first and manifests last, skips blobs that are already installed (after hashing the bundle's copy of
  them, so a damaged part is refused even on re-import), and
  refuses path traversal, links, unknown entries and name conflicts.
- `verify` with `ok` / `missing` / `corrupt` per blob and `--json` output.
- Practice (mock) models with fake weights for trying everything without Ollama.
