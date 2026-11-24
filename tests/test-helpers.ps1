# Test helpers for run-tests.ps1.
Set-StrictMode -Version Latest

function Test {
    param([string]$Name, [scriptblock]$Body)
    $full = "$($script:CurrentFile): $Name"
    if ($full -notlike $Filter) { return }

    try {
        & $Body
        $script:Passed++
        Write-Host "  ok    $full"
    } catch {
        $script:Failed += $full
        Write-Host "  FAIL  $full"
        Write-Host ("        " + ($_.Exception.Message -replace "`n", "`n        "))
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message = '')
    if ($Text -notmatch $Pattern) { throw "Expected /$Pattern/ $Message. Output:`n$Text" }
}

function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Message = '')
    if ($Text -match $Pattern) { throw "Did not expect /$Pattern/ $Message. Output:`n$Text" }
}

function New-TestRoot {
    $path = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $path | Out-Null

    foreach ($name in @('machine', 'state', 'home', 'bin')) {
        New-Item -ItemType Directory -Path (Join-Path $path $name) | Out-Null
    }

    # Fake native commands log their arguments. An exit code comes from
    # NW_FAKE_<COMMAND>_EXIT, or NW_FAKE_WINGET_TEST_EXIT for 'configure test'.
    $winget = @(
        '@echo off'
        'echo winget %*>>"%NW_FAKE_LOG%"'
        'if "%2"=="test" if defined NW_FAKE_WINGET_TEST_EXIT exit /b %NW_FAKE_WINGET_TEST_EXIT%'
        'if defined NW_FAKE_WINGET_EXIT exit /b %NW_FAKE_WINGET_EXIT%'
        'exit /b 0'
    )

    $chezmoi = @(
        '@echo off'
        'echo chezmoi %*>>"%NW_FAKE_LOG%"'
        'if defined NW_FAKE_CHEZMOI_EXIT exit /b %NW_FAKE_CHEZMOI_EXIT%'
        'exit /b 0'
    )

    [System.IO.File]::WriteAllText((Join-Path $path 'bin\winget.cmd'), ($winget -join "`r`n") + "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $path 'bin\chezmoi.cmd'), ($chezmoi -join "`r`n") + "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $path 'log.txt'), '')
    return $path
}

function Set-TestFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"))
}

function New-TestMachine {
    param([string]$Settings = '', [hashtable]$HomeFiles = @{}, [string]$Lock)
    $root = New-TestRoot
    Set-TestFile (Join-Path $root 'machine\machine.psd1') "@{`n    SchemaVersion = 1`n$Settings`n}`n"

    foreach ($relative in $HomeFiles.Keys) {
        Set-TestFile (Join-Path (Join-Path $root 'machine\home') $relative) $HomeFiles[$relative]
    }

    if ($Lock) { Set-TestFile (Join-Path $root 'machine\nacre-windows.lock.json') $Lock }
    return $root
}

# Run a script in a child process of this host with the test environment.
# Returns @{ ExitCode; Output; Log }.
function Invoke-TestScript {
    param([string]$Root, [string]$Script, [string[]]$Arguments = @(), [hashtable]$Environment = @{})

    $variables = @{
        NACRE_WINDOWS_STATE = (Join-Path $Root 'state')
        NACRE_WINDOWS_HOME  = (Join-Path $Root 'home')
        NW_FAKE_LOG         = (Join-Path $Root 'log.txt')
        Path                = (Join-Path $Root 'bin') + ';' + $env:Path
    }

    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    $saved = @{}

    foreach ($key in $variables.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $variables[$key], 'Process')
    }

    # Windows PowerShell 5.1 turns redirected stderr into terminating errors
    # under Stop; the child's own exit code reports failure instead.
    $preference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $output = & $script:Shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $preference
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }

    return @{
        ExitCode = $code
        Output   = $output
        Log      = [System.IO.File]::ReadAllText((Join-Path $Root 'log.txt'))
    }
}

function Invoke-Nw {
    param([string]$Root, [string[]]$Arguments, [hashtable]$Environment = @{})
    $script = Join-Path $script:CoreRoot 'nacre-windows.ps1'
    return (Invoke-TestScript -Root $Root -Script $script -Arguments ($Arguments + @('-Machine', (Join-Path $Root 'machine'))) -Environment $Environment)
}

function Assert-Success {
    param($Result)
    if ($Result.ExitCode -ne 0) { throw "Exit code $($Result.ExitCode). Output:`n$($Result.Output)" }
}

function Assert-Failure {
    param($Result, [string]$Pattern)
    if ($Result.ExitCode -eq 0) { throw "Expected a failure. Output:`n$($Result.Output)" }
    Assert-Match $Result.Output $Pattern 'in the error output'
}

# Build and return the artifact directory.
function Invoke-TestBuild {
    param([string]$Root)
    $result = Invoke-Nw -Root $Root -Arguments @('build')
    Assert-Success $result
    $path = @($result.Output -split "`r?`n" | Where-Object { $_.Trim() })[-1].Trim()
    Assert-True (Test-Path -LiteralPath (Join-Path $path 'receipt.json')) "No artifact at '$path'."
    return $path
}

function Read-TestText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}
