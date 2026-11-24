# Composition model

nacre-windows evaluates machine policy into a fixed artifact. `switch` converges packages first. Then it applies home files from the same artifact.

| Boundary | Owner | Contract |
| --- | --- | --- |
| Public policy | `defaults.psd1`, `lib/configuration.ps1` | Settings, types and defaults |
| Role | `roles/` | `minimal` and `workstation` baselines; `workstation` extends `minimal` |
| Machine | A separate repository based on `templates/machine/` | Role, overrides, personal home files and pins |
| Packages | WinGet DSC v3 | Presence, optional versions, holds and upgrades with `update` |
| Home | chezmoi | Static files and pinned source archives |
| Development links | nacre-windows | Junctions from source targets to local worktrees |
| Runtime preparation | Operator | Credentials, `$PROFILE` lines, Git identity and mutable data |

## Evaluation

`Resolve-NwConfiguration` merges `defaults.psd1`, the role chain and `machine.psd1`. A later layer replaces a value and merges a map key by key. Each layer is validated before the merge.

`Invoke-NwBuild` writes the artifact to `%LOCALAPPDATA%\nacre-windows\builds\<id>`. The identifier hashes the receipt. The receipt holds the resolved configuration, the source pins and the hash of each output. Equal inputs give the same artifact on Windows PowerShell 5.1 and PowerShell 7.

## Ownership

Each target has one owner: the core, the machine or a source. A conflict stops the build. A machine takes over a core file only after `Files` withdraws it.

## Deployment flow

1. Build the artifact.
2. Preflight the source targets. Stop before any change when a target is unsafe.
3. Write `pending.json`.
4. Declare `XDG_CONFIG_HOME`. Stop if it already has another value.
5. Apply the WinGet document.
6. Add new persistent PATH entries to the process.
7. Make the Development junctions. Then apply the chezmoi source.
8. Write `current.json` and remove `pending.json`.

A failure leaves `pending.json` in place, and `doctor` reports it. The stages share no rollback transaction.

## Pins

The machine wrapper pins the core in `nacre-windows.lock.json` with `lock core`. The core pins its default sources in `sources.lock.json`. The machine lock wins for a source with the same `Repo`. Each pin holds a commit and the SHA-256 of its GitHub archive.
