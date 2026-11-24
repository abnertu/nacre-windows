#Requires -Version 5.1
<#
.SYNOPSIS
    Declarative configuration and deployment for existing Windows machines.
.DESCRIPTION
    Commands:
      build     Evaluate the machine into an artifact and print its path.
      plan      Build, then preview package drift, module installs and home changes.
      switch    Build, then apply packages, modules and home files.
      update    Switch, and also upgrade each package without Version or Hold.
                -Yes accepts the WinGet agreement in each command, and skips
                the chezmoi prompts of switch and update.
      doctor    Report drift and conflicts. Changes nothing.
      lock      Pin sources and modules: lock [<Name>...] [-Rev <commit>] [-Version <version>].
                A source takes the newest commit of its default branch, or
                -Rev. A module takes the newest stable Gallery version, or
                -Version. Each option needs exactly one name of its kind.
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
    [ValidateNotNullOrEmpty()]
    [string]$Rev,
    [ValidateNotNullOrEmpty()]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreRoot = $PSScriptRoot

foreach ($name in @('common', 'configuration', 'version', 'gallery', 'lock', 'build', 'modules', 'execution-policy', 'deploy', 'doctor')) {
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

        Lock-NwPins -Config $config -LockPath (Join-Path $machineRoot $script:NwMachineLockName) `
            -LowerLockPaths @(Join-Path $coreRoot 'sources.lock.json') -Names $Names -Rev $Rev -Version $Version
    }
}

# A tolerated native failure, such as a drift test, must not become the exit code.
exit 0
