#Requires -Version 5.1
# Maintainer command: pin every source that defaults.psd1 declares to the
# newest commit of its default branch, in sources.lock.json.
[CmdletBinding()]
param([string[]]$Names = @())

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$coreRoot = Split-Path -Parent $PSScriptRoot
foreach ($name in @('common', 'configuration', 'lock')) {
    . (Join-Path (Join-Path $coreRoot 'lib') "$name.ps1")
}

$defaults = (Read-NwLayer -Path (Join-Path $coreRoot 'defaults.psd1')).Layer
# Roles enable the sources; pin each declared one.
foreach ($source in $defaults['Sources'].Values) { $source['Enable'] = $true }
Lock-NwSourcePins -Config $defaults -LockPath (Join-Path $coreRoot 'sources.lock.json') -Names $Names
