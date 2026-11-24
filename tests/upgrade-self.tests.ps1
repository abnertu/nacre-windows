# upgrade self through the machine wrapper, against a local GitHub stand-in.

$script:UpgradeArchive = $null
$script:UpgradeRepo = 'abnertu/nacre-windows'
$script:OldRev = 'a' * 40
$script:ReleaseRev = 'c' * 40
$script:MainRev = 'd' * 40
$script:FeatureRev = 'e' * 40
$script:PinnedRev = 'f' * 40

function Get-UpgradeLock {
    param([string]$Rev = $script:OldRev, [string]$Ref, [string]$Repo = $script:UpgradeRepo, [string]$Rest = '')
    $refField = ''
    if ($Ref) { $refField = ", `"Ref`": `"$Ref`"" }
    return "{ `"Core`": { `"Repo`": `"$Repo`"$refField, `"Rev`": `"$Rev`", `"Sha256`": `"$('b' * 64)`" }$Rest }"
}

function New-UpgradeFixture {
    param([string]$Lock, [switch]$NoLock)
    if (-not $script:UpgradeArchive) { $script:UpgradeArchive = New-TestCoreArchive }
    $arguments = @{ WithoutRoleModules = $true }
    if (-not $NoLock) { $arguments['Lock'] = $Lock }
    $root = New-TestMachine @arguments
    $machine = Join-Path $root 'machine'
    $wrapper = Join-Path $machine 'nacre.ps1'
    Copy-Item -LiteralPath (Join-Path $script:CoreRoot 'templates\machine\nacre.ps1') -Destination $wrapper
    $repo = $script:UpgradeRepo

    $routes = @{
        "/repos/$repo/releases/latest"                = '{"tag_name":"0.2.0"}'
        "/repos/$repo/commits/0.2.0"                  = "{`"sha`":`"$script:ReleaseRev`"}"
        "/repos/$repo/branches/main"                  = "{`"commit`":{`"sha`":`"$script:MainRev`"}}"
        "/repos/$repo/branches/feature/x"             = "{`"commit`":{`"sha`":`"$script:FeatureRev`"}}"
        "/repos/$repo/compare/0.2.0...$script:OldRev" = '{"status":"behind"}'
    }

    foreach ($rev in @($script:OldRev, $script:ReleaseRev, $script:MainRev, $script:FeatureRev, $script:PinnedRev)) {
        $routes["/$repo/archive/$rev.tar.gz"] = $script:UpgradeArchive.Bytes
    }

    return @{ Root = $root; Machine = $machine; Wrapper = $wrapper; Web = (Start-TestWeb $routes) }
}

function Invoke-Upgrade {
    param($Fixture, [string[]]$Arguments, [hashtable]$Environment = @{}, [string]$Script)
    $variables = @{}
    foreach ($key in $Fixture.Web.Environment.Keys) { $variables[$key] = $Fixture.Web.Environment[$key] }
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    if (-not $Script) { $Script = $Fixture.Wrapper }
    $call = @{ Root = $Fixture.Root; Script = $Script; Arguments = $Arguments; Environment = $variables }
    return (Invoke-TestScript @call)
}

function Read-UpgradeLock {
    param($Fixture)
    return (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $Fixture.Machine 'nacre-windows.lock.json'))))
}

function Read-UpgradeLockBytes {
    param($Fixture)
    $path = Join-Path $Fixture.Machine 'nacre-windows.lock.json'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
}

function Assert-Deployed {
    param($Result, [switch]$WithoutSwitch)
    Assert-Match $Result.Log 'winget export -o'

    if ($WithoutSwitch) {
        Assert-NoMatch $Result.Log 'winget configure -f'
    } else {
        Assert-Match $Result.Log 'winget configure -f'
    }
}

function Test-HasRef {
    param($Lock)
    return [bool]$Lock.Core.PSObject.Properties['Ref']
}

Test 'upgrade self pins the newest release' {
    $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock)

    try {
        $result = Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes')
        Assert-Success $result
        $lock = Read-UpgradeLock $fixture
        Assert-True ($lock.Core.Rev -eq $script:ReleaseRev) "Pinned $($lock.Core.Rev)."
        Assert-True ($lock.Core.Sha256 -eq $script:UpgradeArchive.Sha256) 'The pin does not hold the archive hash.'
        Assert-True (-not (Test-HasRef $lock)) 'A release pin got a Ref.'
        Assert-Match $result.Output ('aaaaaaaaaaaa -> cccccccccccc \(0\.2\.0\)')
        Assert-Deployed $result
    } finally {
        Stop-TestWeb $fixture.Web
    }
}

Test 'upgrade self pins a machine without a pin' {
    foreach ($case in @(@{ NoLock = $true }, @{ Lock = '{ "Sources": {} }' })) {
        $fixture = New-UpgradeFixture @case

        try {
            Assert-Success (Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes'))
            $lock = Read-UpgradeLock $fixture
            Assert-True ($lock.Core.Rev -eq $script:ReleaseRev) "Pinned $($lock.Core.Rev)."
            if ($case.ContainsKey('Lock')) { Assert-True ([bool]$lock.PSObject.Properties['Sources']) 'Sources was dropped.' }
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'upgrade self follows and leaves a branch' {
    $cases = @(
        @{ Lock = (Get-UpgradeLock -Ref 'main'); Arguments = @(); Rev = $script:MainRev; Ref = 'main' }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', 'main'); Rev = $script:MainRev; Ref = 'main' }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', 'feature/x'); Rev = $script:FeatureRev; Ref = 'feature/x' }
        @{ Lock = (Get-UpgradeLock -Rev $script:MainRev -Ref 'main'); Arguments = @('-Release'); Rev = $script:ReleaseRev; Ref = '' }
    )

    foreach ($case in $cases) {
        $fixture = New-UpgradeFixture -Lock $case.Lock

        try {
            $result = Invoke-Upgrade $fixture (@('upgrade', 'self', '-Yes') + $case.Arguments)
            Assert-Success $result
            $lock = Read-UpgradeLock $fixture
            Assert-True ($lock.Core.Rev -eq $case.Rev) "Pinned $($lock.Core.Rev), expected $($case.Rev)."

            if ($case.Ref) {
                Assert-True ($lock.Core.Ref -eq $case.Ref) "Ref is $($lock.Core.Ref)."
                Assert-Match $result.Output ("-> $($case.Rev.Substring(0, 12)) \(" + [regex]::Escape($case.Ref) + '\)')
            } else {
                Assert-True (-not (Test-HasRef $lock)) '-Release kept a Ref.'
            }
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'upgrade self pins one commit' {
    $cases = @(
        @{ Lock = (Get-UpgradeLock -Ref 'main'); Arguments = @(); Ref = 'main' }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', 'main'); Ref = 'main' }
        @{ Lock = (Get-UpgradeLock -Ref 'main'); Arguments = @('-Release'); Ref = '' }
        @{ Lock = (Get-UpgradeLock -Rev 'abc'); Arguments = @(); Ref = '' }
    )

    foreach ($case in $cases) {
        $fixture = New-UpgradeFixture -Lock $case.Lock

        try {
            Assert-Success (Invoke-Upgrade $fixture (@('upgrade', 'self', '-Yes', '-Rev', $script:PinnedRev) + $case.Arguments))
            $lock = Read-UpgradeLock $fixture
            Assert-True ($lock.Core.Rev -eq $script:PinnedRev) "Pinned $($lock.Core.Rev)."

            if ($case.Ref) {
                Assert-True ($lock.Core.Ref -eq $case.Ref) "Ref is $($lock.Core.Ref)."
            } else {
                Assert-True (-not (Test-HasRef $lock)) 'The pin kept a Ref.'
            }
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'upgrade self refuses a downgrade' {
    $cases = @(
        @{ Status = '{"status":"ahead"}'; Pattern = 'is not behind the newest release 0\.2\.0 at c{40} \(GitHub: ahead\).*-Ref main.*-Release' }
        @{ Status = '{"status":"diverged"}'; Pattern = '\(GitHub: diverged\)' }
        @{ Status = $null; Pattern = 'was not found' }
        @{ Status = 'no-release'; Pattern = 'has no release yet.*-Ref <branch>' }
    )

    foreach ($case in $cases) {
        $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock)

        try {
            $compare = "/repos/$script:UpgradeRepo/compare/0.2.0...$script:OldRev"

            if ($case.Status -eq 'no-release') {
                $fixture.Web.Routes.Remove("/repos/$script:UpgradeRepo/releases/latest")
            } elseif ($null -eq $case.Status) {
                $fixture.Web.Routes.Remove($compare)
            } else {
                $fixture.Web.Routes[$compare] = $case.Status
            }

            $before = Read-UpgradeLockBytes $fixture
            Assert-Failure (Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes')) $case.Pattern
            Assert-True ((Read-UpgradeLockBytes $fixture) -eq $before) 'A refused upgrade changed the lock.'
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'upgrade self keeps a current pin' {
    $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock)

    try {
        Assert-Success (Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes'))
        $before = Read-UpgradeLockBytes $fixture
        $archives = @($fixture.Web.Log.ToArray() | Where-Object { $_ -like '*/archive/*' }).Count
        $result = Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes')
        Assert-Success $result
        Assert-True (@($fixture.Web.Log.ToArray() | Where-Object { $_ -like '*/archive/*' }).Count -eq $archives) 'A current pin downloaded an archive.'
        Assert-True ((Read-UpgradeLockBytes $fixture) -eq $before) 'A current pin changed the lock.'
        Assert-Deployed $result
    } finally {
        Stop-TestWeb $fixture.Web
    }
}

Test 'upgrade self verifies the cached core' {
    $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock)

    try {
        Assert-Success (Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes'))
        $core = Join-Path $fixture.Root ("state\core\$script:ReleaseRev")
        Set-TestFile (Join-Path $core 'VERSION') "9.9.9`n"

        foreach ($command in @('plan', 'build')) {
            Assert-Failure (Invoke-Upgrade $fixture @($command)) 'changed: tree hash'
        }

        Remove-Item -LiteralPath ($core + '.json') -Force
        $other = New-TestCoreArchive -Extra 'different'
        $fixture.Web.Routes["/$script:UpgradeRepo/archive/$script:ReleaseRev.tar.gz"] = $other.Bytes
        Assert-Failure (Invoke-Upgrade $fixture @('plan')) 'checksum is'
    } finally {
        Stop-TestWeb $fixture.Web
    }
}

function Invoke-UpgradeAnswer {
    param($Fixture, [hashtable]$Environment, [string[]]$InputText, [switch]$Interactive)
    $variables = @{}
    foreach ($key in $Fixture.Web.Environment.Keys) { $variables[$key] = $Fixture.Web.Environment[$key] }
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    return (Invoke-TestScript -Root $Fixture.Root -Script $Fixture.Wrapper -Arguments @('upgrade', 'self') -Environment $variables -InputText $InputText -Interactive:$Interactive)
}

Test 'upgrade self asks before switch' {
    # Each case differs from the accepted one in one rule only.
    $seam = @{ NACRE_WINDOWS_INTERACTIVE = '1' }

    $cases = @(
        @{ Name = 'accepted'; Environment = $seam; InputText = @('y'); Interactive = $true; Switches = $true }
        @{ Name = 'declined'; Environment = $seam; InputText = @('n'); Interactive = $true; Switches = $false }
        @{ Name = 'end of input'; Environment = $seam; InputText = @(); Interactive = $true; Switches = $false }
        @{ Name = 'redirected input'; Environment = @{}; InputText = @('y'); Interactive = $true; Switches = $false }
        @{ Name = '-NonInteractive host'; Environment = $seam; InputText = @('y'); Interactive = $false; Switches = $false }
    )

    foreach ($case in $cases) {
        $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock)

        try {
            $result = Invoke-UpgradeAnswer $fixture $case.Environment $case.InputText -Interactive:$case.Interactive
            Assert-Success $result
            Assert-True ((Read-UpgradeLock $fixture).Core.Rev -eq $script:ReleaseRev) "$($case.Name): the new pin was not written."
            Assert-Deployed $result -WithoutSwitch:(-not $case.Switches)
            if (-not $case.Switches) { Assert-Match $result.Output 'Run: nacre switch' }
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }
}

Test 'upgrade self keeps the other lock values' {
    $timestamp = '2026-01-01T03:04:05+05:30'
    $rest = ', "Sources": {}, "Metadata": { "Recorded": "' + $timestamp + '" }'
    $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock -Rest $rest)

    try {
        $null = Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes')
        $text = [IO.File]::ReadAllText((Join-Path $fixture.Machine 'nacre-windows.lock.json'))
        Assert-True ($text.Contains($timestamp)) 'upgrade self rewrote a timestamp string.'
        $lock = Read-UpgradeLock $fixture
        Assert-True ($lock.Core.Rev -eq $script:ReleaseRev) 'upgrade self did not write the new pin.'
        Assert-True ([bool]$lock.PSObject.Properties['Sources']) 'upgrade self dropped Sources.'
    } finally {
        Stop-TestWeb $fixture.Web
    }
}

Test 'upgrade self validates a branch and a commit' {
    $cases = @(
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', '..'); Pattern = 'not a valid branch name' }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', 'a//b'); Pattern = 'not a valid branch name' }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', '/a'); Pattern = 'not a valid branch name' }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', 'a.lock/b'); Pattern = 'not a valid branch name' }
        @{ Lock = (Get-UpgradeLock -Ref '..'); Arguments = @(); Pattern = "Core.Ref '\.\.' is not a valid branch name" }
        @{ Lock = (Get-UpgradeLock -Repo 'bad repo'); Arguments = @(); Pattern = 'not an owner/name repository' }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Ref', 'nope'); Pattern = "Branch 'nope' does not exist" }
        @{ Lock = (Get-UpgradeLock); Arguments = @('-Rev', 'abc'); Pattern = 'full 40-character commit' }
    )

    foreach ($case in $cases) {
        $fixture = New-UpgradeFixture -Lock $case.Lock

        try {
            $before = Read-UpgradeLockBytes $fixture
            Assert-Failure (Invoke-Upgrade $fixture (@('upgrade', 'self', '-Yes') + $case.Arguments)) $case.Pattern
            Assert-True ((Read-UpgradeLockBytes $fixture) -eq $before) 'A refused upgrade changed the lock.'
        } finally {
            Stop-TestWeb $fixture.Web
        }
    }

    # Other commands keep -Rev for refs; the wrapper passes it to the core.
    $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock)

    try {
        $missing = Join-Path $fixture.Root 'no-core'
        Assert-Failure (Invoke-Upgrade $fixture @('lock', 'Neovim', '-Rev', 'main', '-OverrideCore', $missing)) 'is not a nacre-windows checkout'
    } finally {
        Stop-TestWeb $fixture.Web
    }
}

Test 'upgrade self runs for another machine and rejects misplaced options' {
    $fixture = New-UpgradeFixture -Lock (Get-UpgradeLock)

    try {
        $elsewhere = Join-Path $fixture.Root 'elsewhere'
        New-Item -ItemType Directory -Path $elsewhere | Out-Null
        $copy = Join-Path $elsewhere 'nacre.ps1'
        Copy-Item -LiteralPath $fixture.Wrapper -Destination $copy
        $result = Invoke-Upgrade $fixture @('upgrade', 'self', '-Yes', '-MachineRoot', $fixture.Machine) -Script $copy
        Assert-Success $result
        Assert-True ((Read-UpgradeLock $fixture).Core.Rev -eq $script:ReleaseRev) 'The machine lock did not get the pin.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $elsewhere 'nacre-windows.lock.json'))) 'The pin went beside the wrapper copy.'
        Assert-Deployed $result

        $misplaced = @(
            @{ Arguments = @('plan', '-Ref', 'main'); Pattern = 'applies only to' }
            @{ Arguments = @('plan', '-MachineRoot', $fixture.Machine); Pattern = 'applies only to' }
            @{ Arguments = @('lock', 'core'); Pattern = "'lock core' was removed" }
            @{ Arguments = @('upgrade', 'self', 'extra'); Pattern = 'takes no names' }
            @{ Arguments = @('upgrade', 'self', '-OverrideCore', $script:CoreRoot); Pattern = 'only previews a local core' }
            @{ Arguments = @('upgrade', 'self', '-Version', '1.0'); Pattern = 'not -Version' }
        )

        foreach ($case in $misplaced) {
            Assert-Failure (Invoke-Upgrade $fixture $case.Arguments) $case.Pattern
        }
    } finally {
        Stop-TestWeb $fixture.Web
    }
}
