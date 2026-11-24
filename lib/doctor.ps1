# Doctor reports drift and conflicts. It changes nothing on the host, but
# its WinGet test can install the WinGet DSC processor on first use.
Set-StrictMode -Version Latest

# Windows defines these names in both scopes itself; PATH is merged.
$script:NwBothScopeNames = @('Path', 'TEMP', 'TMP')

function Get-NwEnvironmentIssues {
    param(
        [System.Collections.IDictionary]$MachineVariables = [Environment]::GetEnvironmentVariables('Machine'),
        [System.Collections.IDictionary]$UserVariables = [Environment]::GetEnvironmentVariables('User'),
        [scriptblock]$TestDirectory = { param($Path) Test-Path -LiteralPath $Path -PathType Container }
    )

    $issues = @()
    $seen = @{}

    foreach ($scope in @('Machine', 'User')) {
        $variables = $MachineVariables
        if ($scope -eq 'User') { $variables = $UserVariables }
        $raw = $null
        foreach ($name in $variables.Keys) { if ([string]$name -ieq 'Path') { $raw = $variables[$name] } }
        if (-not $raw) { continue }

        foreach ($entry in ([string]$raw -split ';')) {
            $trimmed = $entry.Trim()
            if (-not $trimmed) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
            $key = $expanded.Replace('/', '\').TrimEnd('\').ToLowerInvariant()

            if ($seen.ContainsKey($key)) {
                $issues += "$scope PATH repeats a $($seen[$key]) PATH entry: $trimmed"
            } else {
                $seen[$key] = $scope
            }

            if (-not (& $TestDirectory $expanded)) {
                $issues += "$scope PATH entry does not exist: $trimmed"
            }
        }
    }

    # An empty value is usually a failed deletion: from PowerShell, $null
    # passed to SetEnvironmentVariable is stored as "".
    foreach ($scope in @('Machine', 'User')) {
        $variables = $MachineVariables
        if ($scope -eq 'User') { $variables = $UserVariables }

        foreach ($name in (Get-NwSortedKeys $variables)) {
            if (-not $variables[$name]) { $issues += "$scope variable '$name' has an empty value." }
        }
    }

    $machineNames = @($MachineVariables.Keys | ForEach-Object { [string]$_ })

    foreach ($name in (Get-NwSortedKeys $UserVariables)) {
        if ($script:NwBothScopeNames -contains $name) { continue }

        if ($machineNames -contains $name) {
            $issues += "'$name' is defined in both Machine and User scopes; the User value wins."
        }
    }

    return , $issues
}

function Get-NwCommandIssues {
    param([System.Collections.IDictionary]$Commands)
    $issues = @()

    foreach ($name in (Get-NwSortedKeys $Commands)) {
        if (-not $Commands[$name]) { continue }
        $paths = @(Get-Command -Name $name -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
        # One installation can expose foo.exe and foo.cmd in one directory.
        $directories = @($paths | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique)

        if ($paths.Count -eq 0) {
            $issues += "'$name' is not on PATH."
        } elseif ($directories.Count -gt 1) {
            $issues += "'$name' is in more than one PATH directory: $($directories -join '; ')"
        }
    }

    return , $issues
}

function Get-NwDefaultModulePath {
    param([string]$Executable)
    # Clear the inherited path before PowerShell computes its startup defaults.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = '-NoProfile -NonInteractive -Command "[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($env:PSModulePath))"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [void]$start.EnvironmentVariables.Remove('PSModulePath')
    $process = [Diagnostics.Process]::Start($start)

    try {
        $errors = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0 -or $errors.GetAwaiter().GetResult()) {
            throw 'Could not read the default module path.'
        }

        return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($output.Trim()))
    } finally {
        $process.Dispose()
    }
}

function Get-NwModulePathIssues {
    param($Build, [string]$Documents)
    if ((Test-NwAlternateHome) -or -not $Documents) { return }
    $editions = @($Build.Modules.Values | ForEach-Object { $_['Editions'] })
    $declaredDocuments = Get-NwDocumentsDirectory

    foreach ($edition in @('Desktop', 'Core')) {
        if ($edition -notin $editions) { continue }
        $executable = Get-NwPolicyExecutable $edition
        if (-not $executable) { continue }

        try {
            $entries = (Get-NwDefaultModulePath $executable) -split [IO.Path]::PathSeparator
        } catch {
            "Could not check the default PSModulePath for PowerShell $edition."
            continue
        }

        $folder = $script:NwModuleEditionFolders[$edition]
        $root = Join-Path (Join-Path $Documents $folder) 'Modules'
        $declaredRoot = Join-Path (Join-Path $declaredDocuments $folder) 'Modules'

        $matched = $entries | Where-Object {
            $entry = $_.Trim().Replace('/', '\').TrimEnd('\')

            [string]::Equals($entry, $root, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($entry, $declaredRoot, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1

        if (-not $matched) { "PowerShell $edition default PSModulePath does not include '$root'." }
    }
}

function Invoke-NwDoctor {
    param([string]$CoreRoot, [string]$MachineRoot, [switch]$Yes)
    $issues = @()
    $build = Invoke-NwBuild -CoreRoot $CoreRoot -MachineRoot $MachineRoot
    $state = Get-NwStateRoot

    if (Test-Path -LiteralPath (Join-Path $state 'pending.json')) {
        $pending = Read-NwJson (Join-Path $state 'pending.json')
        $issues += "Switch to $($pending['Id']) started at $($pending['Started']) and did not finish. Run switch again."
    }

    $currentPath = Join-Path $state 'current.json'

    if (-not (Test-Path -LiteralPath $currentPath)) {
        $issues += 'This host has no completed switch.'
    } else {
        $current = Read-NwJson $currentPath

        if ($current['Id'] -ne $build.Id) {
            $issues += "The configuration changed since the last switch ($($current['Id']) -> $($build.Id)). Run switch."
        }
    }

    $drift = Get-NwPackageDrift $build.Config
    if ($drift.Failure) { $issues += "Package check failed: $($drift.Failure)" }
    foreach ($line in $drift.Lines) { $issues += "Package drift: $line" }

    if (Test-NwCommand 'chezmoi') {
        $status = @(& chezmoi @(@('status') + (Get-NwChezmoiArguments $build.Path)) 2>&1)

        if ($LASTEXITCODE -ne 0) {
            $issues += "chezmoi status failed (exit $LASTEXITCODE)."
        } elseif ($status.Count -gt 0) {
            $issues += "Home files differ from the artifact:`n    " + (($status | ForEach-Object { [string]$_ }) -join "`n    ")
        }
    } else {
        $issues += 'chezmoi is not on PATH.'
    }

    $issues += Get-NwSourceIssues $build
    $modules = Get-NwModuleState $build
    $issues += $modules.Blocking
    $issues += Get-NwModulePathIssues -Build $build -Documents $modules.Documents
    foreach ($warning in $modules.Warnings) { Write-Warning $warning }

    foreach ($install in $modules.Installs) {
        $issues += "PowerShell module '$($install.Id)' version '$($install.Pin.ModuleVersion)' is missing from '$($install.VersionPath)'. Run switch."
    }

    $issues += @(Get-NwModulePolicyChanges $build | ForEach-Object { $_.Message })

    foreach ($name in (Get-NwSortedKeys $build.Links)) {
        $link = $build.Links[$name]

        if ((Get-NwTargetState -Target $link.Target -Path $link.Path).State -eq 'missing') {
            $issues += "$name is not linked to '$($link.Path)'. Run switch."
        }
    }

    $configHome = Get-NwConfigHomeState $build.Config

    if (@('current', 'alternate') -notcontains $configHome.State) {
        $issues += "XDG_CONFIG_HOME is '$($configHome.Effective)', not '$($configHome.Desired)'."
    }

    # An alternate home is isolated from persistent user and machine settings.
    if (-not (Test-NwAlternateHome)) { $issues += Get-NwEnvironmentIssues }

    $issues += Get-NwCommandIssues $build.Config['Doctor']['Commands']

    foreach ($issue in $issues) { Write-Warning $issue }

    if ($issues.Count -gt 0) {
        throw "Doctor found $($issues.Count) issue(s). Doctor changes nothing; fix them, then run doctor again."
    }

    Write-Host 'Doctor found no issues.'
}
