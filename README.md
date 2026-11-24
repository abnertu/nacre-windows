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

If the local policy is `Restricted`, start the first switch from the Git checkout in a `RemoteSigned` process:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\nacre.ps1 switch
```

## Usage

Preview the changes, then apply them:

```powershell
.\nacre.ps1 plan
.\nacre.ps1 switch
```

| Command | Effect |
| --- | --- |
| `build` | Evaluates the machine and prints the artifact path. |
| `plan` | Builds, then shows package drift, module installs and home changes. Changes nothing. |
| `switch` | Builds, then applies packages, modules and home files. |
| `update` | Does a `switch` and also upgrades each package without `Version` or `Hold`. |
| `doctor` | Reports drift and conflicts. Changes nothing. |
| `lock [<Name>...]` | Pins sources and modules. A source gets the newest commit of its default branch. A module gets the newest stable Gallery version. |
| `lock <Source> -Rev <commit>` | Pins one source to a commit. |
| `lock <Module> -Version <version>` | Pins one module to a Gallery version. |
| `lock core` | Pins the core and keeps the other pins. Only the machine wrapper runs it. |

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
| `Modules` | from the role | PowerShell Gallery modules: `'<Gallery id>' = $true`, `$false`, or `@{ Enable; AcceptLicense }`. |
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
The source name `core` is reserved. Rename any source that uses it, including its lock and Development entries.
A source with another `Repo` needs a machine pin: run `.\nacre.ps1 lock <Source>`.

The archive owns its whole directory. chezmoi removes other files there, such as a `.git` directory.

To develop a source, set its `Development` path to a local worktree. `switch` then makes a junction from the target to the worktree.
`switch` stops when a target is a link but the source uses its archive. Remove the link first, so that the archive cannot replace the worktree.
`switch` also stops when a directory is where a Development link belongs. Move the directory away first.

### Modules

A module is a PowerShell Gallery package at a pinned version. `defaults.psd1` declares `PSReadLine` disabled.
A module name is not a Windows device name, such as `CON`, and not `core`.

`lock <Module>` downloads the package and pins these values:

- `Version`: the Gallery package version.
- `ModuleVersion`: the version in the module manifest.
- `Sha256`: the checksum of the package.
- `Editions`: `Core`, `Desktop` or both, from `CompatiblePSEditions` of the manifest.
- `RequireLicenseAcceptance`: the license flag of the package.
- `Dependencies`: the version ranges of each dependency.

`sources.lock.json` pins the core defaults. `nacre-windows.lock.json` wins over them for the same module.
`lock` stops and keeps the lock file when a new pin is outside a dependency range. Pin one of the two modules with `-Version`.

`build` stops for each of these errors:

- An enabled module has no pin.
- A pin requires license acceptance, and the module has no `AcceptLicense = $true`.
- A dependency is not an enabled module.
- A dependency is outside its range, or lacks an edition of the module that needs it.

`switch` installs missing module versions after the WinGet stage. It verifies the package and publishes each version from a staging directory.
Core modules go to `Documents\PowerShell\Modules`. Desktop modules go to `Documents\WindowsPowerShell\Modules`. Both paths follow the user's Documents folder.

`switch` stops before deployment in these cases:

- The Documents folder is invalid or unavailable.
- A module path below Documents includes a file or link in place of a directory.
- The pinned version directory exists without a regular manifest.
- A home file or source target overlaps a managed module directory.

`plan` lists missing versions and reports module issues. `doctor` reports missing versions and blocking issues.
For installed editions with managed modules, `doctor` checks the module root against the default `PSModulePath`.
Both warn about stale staging and higher installed versions. `switch` removes its stale staging directories.

### Module execution policy

The `minimal` role enables PSReadLine. The `workstation` role inherits it.
Set `Modules = @{ PSReadLine = $false }` to withdraw it.

`switch` checks the persistent policy of each installed PowerShell edition that has a managed module.
It sets `CurrentUser` to `RemoteSigned` for an effective local `Restricted` policy.
A `Restricted` Group Policy stops the switch.
`plan` and `doctor` report policy changes and blockers.
Add custom PowerShell 7 installations to PATH before you run these commands.

### Adopt a new core

The machine wrapper `nacre.ps1` is a copy of `templates/machine/nacre.ps1`. The core cannot update it.
When you adopt a core with module pins, copy its wrapper into the machine repository first. An old wrapper drops `Modules` on `lock core`.
Get the wrapper from one of these places:

- `%LOCALAPPDATA%\nacre-windows\core\<rev>\templates\machine\nacre.ps1`, after a run of the pinned core.
- `https://raw.githubusercontent.com/abnertu/nacre-windows/<rev>/templates/machine/nacre.ps1`.

## Ownership

Each task has one owner:

| Task | Owner |
| --- | --- |
| Package presence, versions and upgrades | WinGet DSC v3 |
| Home files and source archives | chezmoi |
| Installed Gallery module versions and their staging directories | nacre-windows |
| `XDG_CONFIG_HOME`, Development junctions, and the artifacts and receipts in `%LOCALAPPDATA%\nacre-windows` | nacre-windows |
| PATH entries | Package installers. nacre-windows only reads them. |
| `$PROFILE` lines, Git identity in `~/.gitconfig`, credentials and mutable data | The operator |

## Limits

- WinGet installers are not content-addressed. Pin a `Version` where you need a fixed release.
- `switch` ensures package presence. Only `update` upgrades.
- Sources come from GitHub only.
- Disabling a declaration withdraws management only. Existing packages and module versions stay.
- The package, module and home stages run separately. A failure leaves earlier changes in place.

See [CONTEXT.md](CONTEXT.md) for the composition model.
