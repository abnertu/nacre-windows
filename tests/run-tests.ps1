#Requires -Version 5.1
# Run every tests/*.tests.ps1 file. Each test drives the real entry point in
# a child process of the same PowerShell host, with fake winget and chezmoi
# commands and temporary state and home roots. No test touches the live
# home, registry or packages.
[CmdletBinding()]
param([string]$Filter = '*')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CoreRoot = Split-Path -Parent $PSScriptRoot
$script:Shell = (Get-Process -Id $PID).Path
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('nacre-windows-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0
$script:Failed = @()

. (Join-Path $PSScriptRoot 'test-helpers.ps1')

New-Item -ItemType Directory -Path $script:TempRoot | Out-Null

try {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.tests.ps1' | Sort-Object Name) {
        $script:CurrentFile = $file.BaseName
        . $file.FullName
    }
} finally {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$version = $PSVersionTable.PSVersion.ToString()
Write-Host ''
Write-Host "PowerShell $version`: $($script:Passed) passed, $($script:Failed.Count) failed."

if ($script:Failed.Count -gt 0) {
    foreach ($name in $script:Failed) { Write-Host "  FAILED $name" }
    exit 1
}

exit 0
