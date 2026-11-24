# install.ps1 against a local GitHub stand-in, fake winget and temporary roots.

$script:InstallArchive = $null
$script:InstallRepo = 'abnertu/nacre-windows'
$script:InstallRev = 'c' * 40

function New-InstallFixture {
    if (-not $script:InstallArchive) { $script:InstallArchive = New-TestCoreArchive }
    $root = New-TestRoot
    $repo = $script:InstallRepo

    $routes = @{
        "/repos/$repo/releases/latest"             = '{"tag_name":"0.1.0"}'
        "/repos/$repo/commits/0.1.0"               = "{`"sha`":`"$script:InstallRev`"}"
        "/repos/$repo/compare/0.1.0...$('a' * 40)" = '{"status":"behind"}'
        "/$repo/archive/$script:InstallRev.tar.gz" = $script:InstallArchive.Bytes
        "/repos/$repo/branches/main"               = "{`"commit`":{`"sha`":`"$('d' * 40)`"}}"
        "/$repo/archive/$('d' * 40).tar.gz"        = $script:InstallArchive.Bytes
    }

    return @{ Root = $root; Checkout = (Join-Path $root 'home\.config\nacre'); Web = (Start-TestWeb $routes) }
}

function Invoke-Install {
    param($Fixture, [hashtable]$Environment = @{})
    $variables = @{ NACRE_YES = '1' }
    foreach ($key in $Fixture.Web.Environment.Keys) { $variables[$key] = $Fixture.Web.Environment[$key] }
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    return (Invoke-TestScript -Root $Fixture.Root -Script (Join-Path $script:CoreRoot 'install.ps1') -Environment $variables)
}

function New-InstallMachineRepository {
    param([string]$Root, [string]$Wrapper, [string]$Layout = 'windows')
    $work = Join-Path $Root 'machine-work'
    $machine = $work
    if ($Layout) { $machine = Join-Path $work $Layout }
    Set-TestFile (Join-Path $machine 'machine.psd1') "@{`n    SchemaVersion = 1`n    Modules = @{ PSReadLine = `$false }`n}`n"
    Set-TestFile (Join-Path $machine 'nacre.ps1') $Wrapper
    Set-TestFile (Join-Path $work 'flake.nix') "{ }`n"

    foreach ($arguments in @(@('init', '-q'), @('add', '.'), @('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'machine'))) {
        & git -C $work @arguments
        if ($LASTEXITCODE -ne 0) { throw "git $arguments failed." }
    }

    return $work
}

function Read-InstallLock {
    param([string]$Machine)
    return (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $Machine 'nacre-windows.lock.json'))))
}

$script:TemplateWrapper = [IO.File]::ReadAllText((Join-Path $script:CoreRoot 'templates\machine\nacre.ps1'))

Test 'install clones the machine repository' {
    foreach ($layout in @('windows', '')) {
        $fixture = New-InstallFixture

        try {
            $repository = New-InstallMachineRepository -Root $fixture.Root -Wrapper $script:TemplateWrapper -Layout $layout
            $result = Invoke-Install $fixture @{ NACRE_REPO = $repository }
            Assert-NoMatch $result.Output 'Write-Error|Exception'
            $machine = $fixture.Checkout
            if ($layout) { $machine = Join-Path $fixture.Checkout $layout }
            Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Checkout '.git')) 'install did not clone.'
            Assert-True ((Read-InstallLock $machine).Core.Rev -eq $script:InstallRev) "install did not pin the newest release in '$layout'."
            Assert-Match $result.Log 'winget configure -f'
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'install creates a machine from the template' {
    $fixture = New-InstallFixture

    try {
        $result = Invoke-Install $fixture
        Assert-Match $result.Output 'Creating a machine repository from the 0\.1\.0 template'

        foreach ($name in @('machine.psd1', 'nacre.ps1', '.gitattributes', '.git')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Checkout $name)) "The new machine has no $name."
        }

        Assert-True ((Read-InstallLock $fixture.Checkout).Core.Rev -eq $script:InstallRev) 'install did not pin the newest release.'
    } finally {
        Stop-TestWeb $fixture.Web
    }
}

Test 'install refuses before writing' {
    $cases = @(
        @{ Environment = @{ NW_FAKE_WINGET_VERSION = 'v1.10.3' }; Pattern = 'too old' }
        @{ Environment = @{ Path = '{bin};' + [Environment]::SystemDirectory }; Pattern = 'Git is missing' }
        @{ Occupied = $true; Environment = @{}; Pattern = 'is not empty and holds no machine\.psd1' }
    )

    foreach ($case in $cases) {
        $fixture = New-InstallFixture

        try {
            if ($case.ContainsKey('Occupied')) { Set-TestFile (Join-Path $fixture.Checkout 'notes.txt') "keep`n" }
            $environment = @{}
            foreach ($key in $case.Environment.Keys) { $environment[$key] = $case.Environment[$key].Replace('{bin}', (Join-Path $fixture.Root 'bin')) }
            $result = Invoke-Install $fixture $environment
            Assert-ErrorMatch $result.Output $case.Pattern

            if ($case.ContainsKey('Occupied')) {
                Assert-True (@(Get-ChildItem -LiteralPath $fixture.Checkout -Force).Count -eq 1) 'install wrote into an occupied checkout.'
            } else {
                Assert-True (-not (Test-Path -LiteralPath $fixture.Checkout)) 'install wrote a checkout.'
            }

            Assert-NoMatch $result.Log 'winget configure'
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'install upgrades an existing machine' {
    $old = "throw 'the machine wrapper ran'`n"

    $cases = @(
        @{ Yes = '1'; Ref = ''; Rev = $script:InstallRev }
        @{ Yes = ''; Ref = ''; Rev = $script:InstallRev }
        @{ Yes = '1'; Ref = 'main'; Rev = ('d' * 40); Repo = 'git@example.invalid:other.git' }
    )

    foreach ($case in $cases) {
        $yes = $case.Yes
        $fixture = New-InstallFixture

        try {
            $machine = Join-Path $fixture.Checkout 'windows'
            Set-TestFile (Join-Path $machine 'machine.psd1') "@{`n    SchemaVersion = 1`n    Modules = @{ PSReadLine = `$false }`n}`n"
            Set-TestFile (Join-Path $machine 'nacre.ps1') $old
            $refField = ''
            if ($case.Ref) { $refField = ", `"Ref`": `"$($case.Ref)`"" }
            Set-TestFile (Join-Path $machine 'nacre-windows.lock.json') "{ `"Core`": { `"Repo`": `"$script:InstallRepo`"$refField, `"Rev`": `"$('a' * 40)`", `"Sha256`": `"$('b' * 64)`" } }`n"
            $environment = @{ NACRE_YES = $yes }
            if ($case.ContainsKey('Repo')) { $environment['NACRE_REPO'] = $case.Repo }
            $result = Invoke-Install $fixture $environment
            Assert-NoMatch $result.Output 'the machine wrapper ran'
            $lock = Read-InstallLock $machine
            Assert-True ($lock.Core.Rev -eq $case.Rev) "install pinned $($lock.Core.Rev), expected $($case.Rev). Output:`n$($result.Output)"
            if ($case.Ref) { Assert-True ($lock.Core.Ref -eq $case.Ref) 'install changed the channel.' }
            if ($case.ContainsKey('Repo')) { Assert-ErrorMatch $result.Output 'not NACRE_REPO' }
            Assert-Match $result.Log 'winget export -o'

            if ($yes) {
                Assert-Match $result.Log 'winget configure -f'
            } else {
                Assert-NoMatch $result.Log 'winget configure -f'
            }
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'install warns about an outdated wrapper' {
    $cases = @(
        @{ Wrapper = "# an older wrapper`n"; Warns = $true }
        @{ Wrapper = $script:TemplateWrapper.Replace("`n", "`r`n"); Warns = $false }
    )

    foreach ($case in $cases) {
        $fixture = New-InstallFixture

        try {
            $machine = $fixture.Checkout
            Set-TestFile (Join-Path $machine 'machine.psd1') "@{`n    SchemaVersion = 1`n    Modules = @{ PSReadLine = `$false }`n}`n"
            [IO.File]::WriteAllText((Join-Path $machine 'nacre.ps1'), $case.Wrapper)
            $result = Invoke-Install $fixture
            $flat = ($result.Output -replace '(?m)^\s*\|', '') -replace '\s+', ''
            Assert-True (($flat -match 'differsfromthe0\.1\.0template') -eq $case.Warns) "Warning shown: $(-not $case.Warns). Output:`n$($result.Output)"
            Assert-True ([IO.File]::ReadAllText((Join-Path $machine 'nacre.ps1')) -eq $case.Wrapper) 'install changed the machine wrapper.'
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'install keeps the session of Invoke-Expression' {
    $fixture = New-InstallFixture

    try {
        $driver = Join-Path $fixture.Root 'driver.ps1'
        $installer = Join-Path $script:CoreRoot 'install.ps1'

        $lines = @(
            'Set-StrictMode -Off'
            "`$ErrorActionPreference = 'Continue'"
            "Invoke-Expression ([IO.File]::ReadAllText('$installer'))"
            'Write-Output "after preference=$ErrorActionPreference undefined=$($null -eq $notDefinedAnywhere)"'
        )

        Set-TestFile $driver ($lines -join "`n")
        $environment = @{ NW_FAKE_WINGET_VERSION = 'v1.0.0' }
        foreach ($key in $fixture.Web.Environment.Keys) { $environment[$key] = $fixture.Web.Environment[$key] }
        $result = Invoke-TestScript -Root $fixture.Root -Script $driver -Environment $environment
        Assert-ErrorMatch $result.Output 'too old'
        Assert-Match $result.Output 'after preference=Continue undefined=True'
    } finally {
        Stop-TestWeb $fixture.Web
    }
}
