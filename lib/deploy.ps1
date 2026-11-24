# Plan and switch. Switch converges packages first, then home files.
# The two stages share no rollback transaction.
Set-StrictMode -Version Latest

# WINGET_CONFIG_ERROR_WARNING_NOT_ACCEPTED (0x8A15C00B): the user declined the
# configuration agreement or a warning.
$script:NwWinGetAgreementDeclined = -1978286069

function Get-NwChezmoiArguments {
    param([string]$ArtifactPath)
    $state = Get-NwStateRoot

    return @(
        '--source', (Join-Path $ArtifactPath 'home'),
        '--destination', (Get-NwHomeRoot),
        '--config', (Join-Path $ArtifactPath 'chezmoi.toml'),
        '--persistent-state', (Join-Path $state 'chezmoistate.boltdb'),
        '--cache', (Join-Path $state 'chezmoi-cache')
    )
}

function Get-NwConfigHomeState {
    param([System.Collections.IDictionary]$Config)
    $desired = Join-Path (Get-NwHomeRoot) (($Config['ConfigHome'] -replace '/', '\').Trim('\'))
    # The persistent variable belongs to the real home, not to an alternate one.
    if (Test-NwAlternateHome) { return @{ Desired = $desired; Effective = $null; State = 'alternate' } }
    $user = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'User')
    $machine = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'Machine')
    $effective = $machine
    if ($user) { $effective = $user }
    $state = 'missing'

    if ($effective) {
        $state = 'different'
        if ($effective.TrimEnd('\') -ieq $desired.TrimEnd('\')) { $state = 'current' }
    }

    return @{ Desired = $desired; Effective = $effective; State = $state }
}

# Neovim and WezTerm both read XDG_CONFIG_HOME on Windows. Declaring it
# gives every source one config root, as on Linux.
function Set-NwConfigHome {
    param([System.Collections.IDictionary]$Config)
    $configHome = Get-NwConfigHomeState $Config

    switch ($configHome.State) {
        'different' {
            throw "XDG_CONFIG_HOME is '$($configHome.Effective)', not '$($configHome.Desired)'. Change ConfigHome or the variable, then switch again."
        }
        'missing' {
            [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $configHome.Desired, 'User')
            Write-Host "Set User XDG_CONFIG_HOME to '$($configHome.Desired)'."
        }
    }

    $env:XDG_CONFIG_HOME = $configHome.Desired
}

# A Development source is a junction from its target to a local worktree.
# State: missing, directory, linked (to the expected path) or other-link.
function Get-NwTargetState {
    param([string]$Target, [string]$Path)
    $full = Join-Path (Get-NwHomeRoot) ($Target -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { return @{ Full = $full; State = 'missing'; LinkTarget = $null } }
    $item = Get-Item -LiteralPath $full -Force

    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return @{ Full = $full; State = 'directory'; LinkTarget = $null }
    }

    $linkTarget = [string](@($item.Target)[0])
    $state = 'other-link'
    if ($Path -and $linkTarget.TrimEnd('\') -ieq $Path.TrimEnd('\')) { $state = 'linked' }
    return @{ Full = $full; State = $state; LinkTarget = $linkTarget }
}

# Report each source target that switch cannot converge safely.
function Get-NwSourceIssues {
    param($Build)
    $issues = @()

    # An archive applied through a junction would replace the worktree,
    # .git included, because the archive owns its directory exactly.
    foreach ($name in (Get-NwSortedKeys $Build.Archives)) {
        $state = Get-NwTargetState -Target $Build.Archives[$name]

        if ($state.State -eq 'other-link') {
            $issues += "$name`: '$($state.Full)' is a link to '$($state.LinkTarget)'. Remove the link, then switch again."
        }
    }

    foreach ($name in (Get-NwSortedKeys $Build.Links)) {
        $link = $Build.Links[$name]

        if (-not (Test-Path -LiteralPath $link.Path -PathType Container)) {
            $issues += "$name`: the Development path '$($link.Path)' is not a directory."
        }

        $state = Get-NwTargetState -Target $link.Target -Path $link.Path

        switch ($state.State) {
            'directory' { $issues += "$name`: '$($state.Full)' exists. Move it away, then switch again to link '$($link.Path)'." }
            'other-link' { $issues += "$name`: '$($state.Full)' links to '$($state.LinkTarget)', not '$($link.Path)'." }
        }
    }

    return , $issues
}

function Set-NwSourceLinks {
    param($Build)

    foreach ($name in (Get-NwSortedKeys $Build.Links)) {
        $link = $Build.Links[$name]
        $state = Get-NwTargetState -Target $link.Target -Path $link.Path

        if ($state.State -eq 'missing') {
            New-NwDirectory (Split-Path -Parent $state.Full)
            New-Item -ItemType Junction -Path $state.Full -Target $link.Path | Out-Null
            Write-Host "Linked $name`: $($state.Full) -> $($link.Path)"
        }
    }
}

function Invoke-NwPlan {
    param([string]$CoreRoot, [string]$MachineRoot, [switch]$Yes)
    $build = Invoke-NwBuild -CoreRoot $CoreRoot -MachineRoot $MachineRoot
    Write-Host "Artifact $($build.Id): $($build.Path)"
    $drift = Get-NwPackageDrift $build.Config

    if ($drift.Failure) {
        Write-Warning "Package check skipped: $($drift.Failure)"
    } elseif ($drift.Lines.Count -eq 0) {
        Write-Host 'Packages: each declared package is installed.'
    } else {
        foreach ($line in $drift.Lines) { Write-Host $line }
    }

    $configHome = Get-NwConfigHomeState $build.Config

    switch ($configHome.State) {
        'missing' { Write-Host "Switch sets User XDG_CONFIG_HOME to '$($configHome.Desired)'." }
        'different' { Write-Warning "Switch stops: XDG_CONFIG_HOME is '$($configHome.Effective)', not '$($configHome.Desired)'." }
    }

    foreach ($issue in (Get-NwSourceIssues $build)) { Write-Warning "Switch stops: $issue" }

    $modules = Get-NwModuleState $build
    foreach ($issue in $modules.Blocking) { Write-Warning "Switch stops: $issue" }
    foreach ($warning in $modules.Warnings) { Write-Warning $warning }

    foreach ($install in $modules.Installs) {
        Write-Host "Switch installs PowerShell module '$($install.Id)' version '$($install.Pin.ModuleVersion)' to '$($install.VersionPath)'."
    }

    foreach ($change in (Get-NwModulePolicyChanges $build)) {
        if ($change.Blocking) { Write-Warning "Switch stops: $($change.Message)" } else { Write-Host $change.Message }
    }

    foreach ($name in (Get-NwSortedKeys $build.Links)) {
        Write-Host "$name is linked to the Development path '$($build.Links[$name].Path)'."
    }

    if (Test-NwCommand 'chezmoi') {
        Invoke-NwNative -Command 'chezmoi' -Arguments (@('diff', '--no-pager') + (Get-NwChezmoiArguments $build.Path))
    } else {
        Write-Host 'chezmoi is not installed yet; switch installs it before the home diff.'
    }

    Write-Host 'Plan changes nothing.'
}

function Assert-NwSwitchPreflight {
    param($Build, $ModuleState)
    $issues = (Get-NwSourceIssues $Build) + $ModuleState.Blocking
    $issues += @(Get-NwModulePolicyChanges $Build | Where-Object { $_.Blocking } | ForEach-Object { $_.Message })

    if ($issues.Count -gt 0) {
        throw ("Switch changed nothing:" + [Environment]::NewLine + '  ' + ($issues -join ([Environment]::NewLine + '  ')))
    }
}

function Invoke-NwSwitch {
    param([string]$CoreRoot, [string]$MachineRoot, [switch]$Update, [switch]$Yes)
    $build = Invoke-NwBuild -CoreRoot $CoreRoot -MachineRoot $MachineRoot
    Write-Host "Artifact $($build.Id): $($build.Path)"
    $moduleState = Get-NwModuleState $build
    Assert-NwSwitchPreflight -Build $build -ModuleState $moduleState

    if (-not $moduleState.Documents) {
        Invoke-NwDeployment -Build $build -ModuleState $moduleState -Update:$Update -Yes:$Yes
        return
    }

    # Local users can run multiple switches against one redirected path.
    # Hold the mutex through deployment so only one switch owns staging.
    $documents = $moduleState.Documents.TrimEnd('\')
    $key = Get-NwTextSha256 $documents.ToUpperInvariant()
    $mutex = New-Object Threading.Mutex($false, "Global\nacre-windows-modules-$key")
    $locked = $false

    try {
        try {
            $locked = $mutex.WaitOne()
        } catch [Threading.AbandonedMutexException] {
            $locked = $true
        }

        $moduleState = Get-NwModuleState $build
        Assert-NwSwitchPreflight -Build $build -ModuleState $moduleState

        if (-not [string]::Equals($moduleState.Documents.TrimEnd('\'), $documents, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Switch changed nothing: the Documents directory changed during preflight. Run switch again.'
        }

        Invoke-NwDeployment -Build $build -ModuleState $moduleState -Update:$Update -Yes:$Yes
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-NwDeployment {
    param($Build, $ModuleState, [switch]$Update, [switch]$Yes)
    $state = Get-NwStateRoot
    $pending = Join-Path $state 'pending.json'
    # Record the intent before a mutation; clear it after success.
    Write-NwJson $pending @{ Id = $build.Id; Started = (Get-Date).ToUniversalTime().ToString('o') }

    Set-NwConfigHome $build.Config

    $document = 'configuration.winget'
    if ($Update) { $document = 'configuration-update.winget' }
    $arguments = @('configure', '-f', (Join-Path $build.Path $document))
    if ($Yes) { $arguments += '--accept-configuration-agreements' }
    Invoke-NwNative -Command 'winget' -Arguments $arguments -AllowFailure

    if ($script:NwExitCode -eq $script:NwWinGetAgreementDeclined) {
        # WinGet applied nothing; this switch did not start.
        Remove-Item -LiteralPath $pending -Force
        Write-Host 'Not applied: the WinGet configuration agreement was declined. Run switch again and accept it, or add -Yes.'
        return
    }

    if ($script:NwExitCode -ne 0) { throw "'winget $($arguments -join ' ')' failed with exit code $($script:NwExitCode)." }

    Update-NwProcessPath

    if (-not (Test-NwCommand 'chezmoi')) {
        throw 'chezmoi is not on PATH after the package stage. Declare twpayne.chezmoi or install chezmoi.'
    }

    Set-NwModulePolicies $build
    Install-NwModules $ModuleState
    Set-NwSourceLinks $build
    $apply = @('apply') + (Get-NwChezmoiArguments $build.Path)
    # Interactive apply asks before it replaces a file that differs.
    if (-not $Yes) { $apply += '--interactive' }
    Invoke-NwNative -Command 'chezmoi' -Arguments $apply

    Write-NwJson (Join-Path $state 'current.json') @{
        Id       = $build.Id
        Path     = $build.Path
        Switched = (Get-Date).ToUniversalTime().ToString('o')
    }

    Remove-Item -LiteralPath $pending -Force
    Write-Host "Switched to $($build.Id)."
}
