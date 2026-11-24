# Each PowerShell edition stores its own persistent execution policy.
Set-StrictMode -Version Latest

$script:NwExecutionPolicyProbe = {
    param([switch]$Apply)

    # The caller clears the transient policy in this child process.
    if ((Get-ExecutionPolicy) -ne 'Restricted') { return 'Current' }

    foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
        if ((Get-ExecutionPolicy -Scope $scope) -ne 'Undefined') { return $scope }
    }

    if (-not $Apply) { return 'Change' }
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force

    if ((Get-ExecutionPolicy -Scope CurrentUser) -ne 'RemoteSigned' -or (Get-ExecutionPolicy) -ne 'RemoteSigned') {
        throw 'The effective CurrentUser execution policy did not become RemoteSigned.'
    }

    return 'Changed'
}

function Get-NwPolicyExecutable {
    param([string]$Edition)

    if ($Edition -eq 'Desktop') {
        $path = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        if ($PSEdition -eq 'Desktop') { $path = Join-Path $PSHOME 'powershell.exe' }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        return
    }

    if ($PSEdition -eq 'Core') { return (Join-Path $PSHOME 'pwsh.exe') }
    $command = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    if ($env:ProgramFiles) {
        $path = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
}

function Invoke-NwPolicyProbe {
    param([string]$Edition, [string]$Executable, [switch]$Apply)

    # Run inline because Restricted prevents executing a script file.
    $command = '$ErrorActionPreference = ''Stop''; $ProgressPreference = ''SilentlyContinue''; $env:PSExecutionPolicyPreference = $null; & {' +
    $script:NwExecutionPolicyProbe.ToString() + '}'

    if ($Apply) { $command += ' -Apply' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    # Windows PowerShell can turn redirected native stderr into error records.
    $ErrorActionPreference = 'Continue'
    $output = @(& $Executable -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1)
    $exitCode = $LASTEXITCODE
    $expected = @('Current', 'MachinePolicy', 'UserPolicy')
    if ($Apply) { $expected += 'Changed' } else { $expected += 'Change' }

    if ($exitCode -ne 0 -or $output.Count -ne 1 -or $output[0] -cnotin $expected) {
        throw "Could not check or apply the PowerShell $Edition execution policy (exit $exitCode)."
    }

    return $output[0]
}

function Get-NwPolicyBlocker {
    param([string]$Edition, [string]$Scope)
    return "PowerShell $Edition Group Policy ($Scope) is Restricted. Contact the policy administrator before installing modules."
}

function Get-NwModulePolicyChanges {
    param($Build)
    if ((Test-NwAlternateHome) -or $Build.Modules.Count -eq 0) { return }

    $editions = @($Build.Modules.Values | ForEach-Object { $_['Editions'] })

    foreach ($edition in @('Desktop', 'Core')) {
        if ($edition -notin $editions) { continue }
        $executable = Get-NwPolicyExecutable $edition
        if (-not $executable) { continue }
        $status = Invoke-NwPolicyProbe -Edition $edition -Executable $executable
        if ($status -eq 'Current') { continue }

        $blocking = $status -ne 'Change'
        $message = "Switch sets the PowerShell $edition CurrentUser execution policy to RemoteSigned."
        if ($blocking) { $message = Get-NwPolicyBlocker -Edition $edition -Scope $status }
        @{ Edition = $edition; Executable = $executable; Blocking = $blocking; Message = $message }
    }
}

function Set-NwModulePolicies {
    param($Build)
    $changes = @(Get-NwModulePolicyChanges $Build)
    $blockers = @($changes | Where-Object { $_.Blocking } | ForEach-Object { $_.Message })
    if ($blockers.Count -gt 0) { throw ($blockers -join "`n") }

    foreach ($change in $changes) {
        $status = Invoke-NwPolicyProbe -Edition $change.Edition -Executable $change.Executable -Apply
        if ($status -in @('MachinePolicy', 'UserPolicy')) { throw (Get-NwPolicyBlocker -Edition $change.Edition -Scope $status) }
        if ($status -eq 'Changed') { Write-Host "Set the PowerShell $($change.Edition) CurrentUser execution policy to RemoteSigned." }
    }
}
