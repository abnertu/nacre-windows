# nacre-windows

Declarative configuration and deployment for existing Windows machines.

[![Validate](https://github.com/abnertu/nacre-windows/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/abnertu/nacre-windows/actions/workflows/validate.yml?query=branch%3Amain) [![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://microsoft.com/PowerShell)

A machine repository declares only what differs from the defaults.
nacre-windows evaluates the machine into a static artifact: a WinGet DSC v3 document and a chezmoi source.
`switch` applies that artifact and evaluates nothing again.

## Install

Requirements:

- Windows 10 1809 or later, or Windows 11.
- [WinGet](https://github.com/microsoft/winget-cli) 1.11 or later.

Each role installs [chezmoi](https://www.chezmoi.io/).

To start a machine repository:

1. Copy `templates/machine` into a Git repository.
2. Edit `machine.psd1`. Remove each setting that you keep at its default.
3. Pin the core:

   ```powershell
   .\nacre.ps1 lock core
   ```

On a new host, clone the machine repository and run `.\nacre.ps1 switch`.
The wrapper downloads the pinned core and verifies its SHA-256 checksum.

## Usage

Preview the changes, then apply them:

```powershell
.\nacre.ps1 plan
.\nacre.ps1 switch
```

| Command | Effect |
| --- | --- |
| `build` | Evaluates the machine and prints the artifact path. |
| `plan` | Builds, then shows package drift and home changes. Changes nothing. |
| `switch` | Builds, then applies packages and then home files. |
| `update` | Does a `switch` and also upgrades each package without `Version` or `Hold`. |
| `doctor` | Reports drift and conflicts. Changes nothing. |
| `lock [<Source>...]` | Pins sources to the newest commit of their default branch. Use `-Rev` for one commit. |
| `lock core` | Pins the core. Only the machine wrapper runs it. |

`-Yes` accepts the WinGet configuration agreement, which each command asks for. In `switch` and `update`, it also applies home files without prompts.
To preview core changes, add `-OverrideCore <path>` with a core checkout. Then publish the changes and run `lock core`.

`plan` and `doctor` run `winget configure test`. Its first run can install the WinGet DSC processor.

## Configuration

Precedence, from low to high: `defaults.psd1`, the role chain in `roles/`, then `machine.psd1`.
A later layer replaces a value and merges a map key by key.
Load order does not set precedence.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SchemaVersion` | required | Must be `1`. |
| `Role` | `workstation` | `minimal` has the core, shell and development tools. `workstation` adds WezTerm. |
| `ConfigHome` | `.config` | Home-relative config root. `switch` declares it as `XDG_CONFIG_HOME`. |
| `Packages` | from the role | `'<WinGet id>' = $true`, `$false`, or `@{ Enable; Version; Hold; Source }`. `Hold` keeps an installed version during `update`. |
| `Files` | all core files | `'<target>' = $false` withdraws a core home file. |
| `Sources` | from the role | Pinned config directories: `@{ Enable; Repo; Target }`. |
| `Development` | none | `'<Source>' = '<absolute path>'` links a local worktree instead of the pin. |
| `Doctor.Commands` | from the role | Commands that must be in exactly one PATH directory. |

`machine.psd1` holds constants only. nacre-windows rejects an unknown setting and a value of the wrong type.
`templates/machine/machine.psd1` shows each setting.

### Home files

The core owns `home/`. The machine owns its own `home/`. Both use chezmoi source names.

- Each target has one owner. To replace a core file, withdraw it in `Files` and add your file.
- Declare static files only. nacre-windows rejects scripts, templates, symlinks, removals and encrypted files.
- A home file cannot be inside a source directory.
- Put personal PowerShell code in `.config/powershell/profile.d/*.ps1`. The core profile loads it.

Add this line to `$PROFILE.CurrentUserCurrentHost` of each PowerShell host:

```powershell
. (Join-Path $HOME '.config/powershell/profile.ps1')
```

### Sources

A source is a config directory from one GitHub commit. The `minimal` role enables Neovim, and the `workstation` role adds WezTerm.
`sources.lock.json` pins the core defaults. `nacre-windows.lock.json` in the machine repository wins over them.
A source with another `Repo` needs a machine pin: run `.\nacre.ps1 lock <Source>`.

The archive owns its whole directory. chezmoi removes other files there, such as a `.git` directory.

To develop a source, set its `Development` path to a local worktree. `switch` then makes a junction from the target to the worktree.
`switch` stops when a target is a link but the source uses its archive. Remove the link first, so that the archive cannot replace the worktree.
`switch` also stops when a directory is where a Development link belongs. Move the directory away first.

## Ownership

Each task has one owner:

| Task | Owner |
| --- | --- |
| Package presence, versions and upgrades | WinGet DSC v3 |
| Home files and source archives | chezmoi |
| `XDG_CONFIG_HOME`, Development junctions, and the artifacts and receipts in `%LOCALAPPDATA%\nacre-windows` | nacre-windows |
| PATH entries | Package installers. nacre-windows only reads them. |
| `$PROFILE` lines, Git identity in `~/.gitconfig`, credentials and mutable data | The operator |

## Limits

- WinGet installers are not content-addressed. Pin a `Version` where you need a fixed release.
- `switch` ensures package presence. Only `update` upgrades.
- Sources come from GitHub only.
- Disabling a declaration withdraws management only. nacre-windows uninstalls and deletes nothing.
- The package and home stages share no rollback transaction.

See [CONTEXT.md](CONTEXT.md) for the composition model.
