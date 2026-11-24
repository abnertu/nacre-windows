#Requires -Version 5.1
# Maintainer command: pin every source and module that defaults.psd1
# declares, or the named ones, in sources.lock.json. A source takes the
# newest commit of its default branch, or -Rev. A module takes the newest
# stable Gallery version, or -Version.
#
#   scripts/update-lock.ps1 [<Name>...] [-Rev <commit>] [-Version <version>]
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Names = @(),

    [ValidateNotNullOrEmpty()]
    [string]$Rev,
    [ValidateNotNullOrEmpty()]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$coreRoot = Split-Path -Parent $PSScriptRoot

foreach ($name in @('common', 'configuration', 'version', 'gallery', 'lock')) {
    . (Join-Path (Join-Path $coreRoot 'lib') "$name.ps1")
}

$defaults = (Read-NwLayer -Path (Join-Path $coreRoot 'defaults.psd1')).Layer
# Roles enable the defaults; pin each declared one.
foreach ($source in $defaults['Sources'].Values) { $source['Enable'] = $true }
foreach ($module in $defaults['Modules'].Values) { $module['Enable'] = $true }
Lock-NwPins -Config $defaults -LockPath (Join-Path $coreRoot 'sources.lock.json') -Names $Names -Rev $Rev -Version $Version
