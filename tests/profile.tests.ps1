# The nacre function of the core PowerShell profile.

function Invoke-TestProfile {
    param([string]$Root, [hashtable]$Environment = @{})
    $driver = Join-Path $Root 'driver.ps1'
    $profilePath = Join-Path $script:CoreRoot 'files\home\.config\powershell\profile.ps1'
    $elsewhere = Join-Path $Root 'elsewhere'
    New-Item -ItemType Directory -Force -Path $elsewhere | Out-Null

    $lines = @(
        ". '$profilePath'"
        "Set-Location -LiteralPath '$elsewhere'"
        # A caught error prints its whole message on one line.
        "`$ErrorActionPreference = 'Stop'"
        'try { nacre plan extra -Yes } catch { Write-Output "error=$($_.Exception.Message)" }'
        'Write-Output "code=$LASTEXITCODE"'
    )

    Set-TestFile $driver ($lines -join "`n")
    return Invoke-TestScript -Root $Root -Script $driver -Environment $Environment
}

function New-TestCheckout {
    param([string]$Machine)
    New-Item -ItemType Directory -Force -Path $Machine | Out-Null
    Set-TestFile (Join-Path $Machine 'machine.psd1') "@{ SchemaVersion = 1 }`n"

    $lines = @(
        'param([Parameter(Position = 0)][string]$Command, [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Names, [switch]$Yes)'
        'Write-Output "wrapper $Command $($Names -join ",") yes=$Yes at $PSScriptRoot"'
        'exit 7'
    )

    Set-TestFile (Join-Path $Machine 'nacre.ps1') ($lines -join "`n")
}

Test 'the nacre function runs the machine wrapper' {
    $cases = @(
        @{ Checkout = 'checkout'; Machine = 'checkout'; UseDir = $true }
        @{ Checkout = 'checkout'; Machine = 'checkout\windows'; UseDir = $true }
        @{ Checkout = 'home\.config\nacre'; Machine = 'home\.config\nacre\windows'; UseDir = $false }
    )

    foreach ($case in $cases) {
        $root = New-TestRoot
        $machine = Join-Path $root $case.Machine
        New-TestCheckout $machine
        $environment = @{}
        if ($case.UseDir) { $environment['NACRE_DIR'] = Join-Path $root $case.Checkout }
        $result = Invoke-TestProfile -Root $root -Environment $environment
        Assert-Match $result.Output ('wrapper plan extra yes=True at ' + [regex]::Escape($machine))
        Assert-Match $result.Output 'code=7'
    }

    $root = New-TestRoot
    $result = Invoke-TestProfile -Root $root
    $checkout = Join-Path $root 'home\.config\nacre'
    Assert-Match $result.Output ("error=No nacre-windows machine in '" + [regex]::Escape($checkout) + "' or '" + [regex]::Escape((Join-Path $checkout 'windows')) + "'")
}
