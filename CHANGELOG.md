# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-11-25

### Fixed

- `plan` and `doctor` confirm each package that `winget export` leaves out with `winget list`, so installed packages that export does not match, such as Node.js LTS or WezTerm, are no longer reported as missing.

## [0.1.3] - 2026-11-25

### Fixed

- `plan` and `doctor` no longer report an installed package as missing when its source no longer offers the installed version, such as an older Node.js LTS.
- The wrapper, the core and `install.ps1` hide PowerShell's own progress bars, which left broken lines behind.

## [0.1.2] - 2026-11-25

### Changed

- `plan` and `doctor` compare the declared packages with one `winget export` instead of a WinGet DSC test per package, which is much faster. They no longer ask for the configuration agreement.
- `install.ps1` runs the release wrapper in its own process, as the `nacre` function does, so WinGet draws its progress bar correctly. A process that blocks script files still uses a `RemoteSigned` child process.

## [0.1.1] - 2026-11-25

### Fixed

- `upgrade self` and `install.ps1` keep WinGet on the console, so its progress bar, colors and non-ASCII text show correctly.
- A declined WinGet configuration agreement ends `switch` with a one-line note and leaves no pending marker.

## [0.1.0] - 2026-11-24

### Added

- `install.ps1`, a release asset: `irm https://github.com/abnertu/nacre-windows/releases/latest/download/install.ps1 | iex` sets up a machine repository or upgrades the existing one.
- `upgrade self` pins the newest core on the lock's channel (`Core.Ref`, or the newest release), then plans, asks and switches.
- The core PowerShell profile defines `nacre`, which runs the machine wrapper from any directory.
- Each cached core is verified against its pin through recorded archive and tree hashes.

### Changed

- `update` is now `upgrade system`.
- Home files live in `files/home/` (core) and `files/` (machine) under their target names. Build derives the chezmoi source names.

### Removed

- `lock core`; run `upgrade self`.

[Unreleased]: https://github.com/abnertu/nacre-windows/compare/0.1.4...HEAD
[0.1.4]: https://github.com/abnertu/nacre-windows/compare/0.1.3...0.1.4
[0.1.3]: https://github.com/abnertu/nacre-windows/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/abnertu/nacre-windows/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/abnertu/nacre-windows/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/abnertu/nacre-windows/releases/tag/0.1.0
