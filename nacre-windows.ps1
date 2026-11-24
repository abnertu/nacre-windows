#Requires -Version 5.1
<#
.SYNOPSIS
    Declarative configuration and deployment for existing Windows machines.
.DESCRIPTION
    Commands:
      build     Evaluate the machine into an artifact and print its path.
      plan      Build, then preview package drift and home changes.
      switch    Build, then apply packages and home files.
      update    Switch, and also upgrade each package without Version or Hold.
                -Yes accepts the WinGet agreement in each command, and skips
                the chezmoi prompts of switch and update.
      doctor    Report drift and conflicts. Changes nothing.
      lock      Pin sources to their newest commit: lock [<Source>...] [-Rev <commit>].
      version   Print the core version.
.EXAMPLE
    .\nacre-windows.ps1 plan -Machine ..\machines\windows
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'plan', 'switch', 'update', 'doctor', 'lock', 'version', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Names = @(),

    # The machine directory, which holds machine.psd1. Default: the current directory.
    [string]$Machine = (Get-Location).Path,

    [switch]$Yes,
    [string]$Rev
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreRoot = $PSScriptRoot
foreach ($name in @('common', 'configuration', 'lock', 'build', 'deploy', 'doctor')) {
    . (Join-Path (Join-Path $coreRoot 'lib') "$name.ps1")
}

if ($Command -eq 'help') {
    Get-Help $PSCommandPath -Detailed
    return
}
if ($Command -eq 'version') {
    Write-Output ([System.IO.File]::ReadAllText((Join-Path $coreRoot 'VERSION'))).Trim()
    return
}

$machineRoot = (Resolve-Path -LiteralPath $Machine).Path
if ($Names.Count -gt 0 -and $Command -ne 'lock') {
    throw "'$Command' takes no names: $($Names -join ' ')."
}

switch ($Command) {
    'build' {
        $build = Invoke-NwBuild -CoreRoot $coreRoot -MachineRoot $machineRoot
        Write-Output $build.Path
    }
    'plan' { Invoke-NwPlan -CoreRoot $coreRoot -MachineRoot $machineRoot -Yes:$Yes }
    'switch' { Invoke-NwSwitch -CoreRoot $coreRoot -MachineRoot $machineRoot -Yes:$Yes }
    'update' { Invoke-NwSwitch -CoreRoot $coreRoot -MachineRoot $machineRoot -Update -Yes:$Yes }
    'doctor' { Invoke-NwDoctor -CoreRoot $coreRoot -MachineRoot $machineRoot -Yes:$Yes }
    'lock' {
        $config = Resolve-NwConfiguration -CoreRoot $coreRoot -MachineRoot $machineRoot
        Lock-NwSourcePins -Config $config -LockPath (Join-Path $machineRoot $script:NwMachineLockName) -Names $Names -Rev $Rev
    }
}
# A tolerated native failure, such as a drift test, must not become the exit code.
exit 0
