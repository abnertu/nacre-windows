# Module pins: lock against a local gallery, pin validation and the checks
# that run before lock writes.

. (Join-Path $script:CoreRoot 'lib\common.ps1')
. (Join-Path $script:CoreRoot 'lib\configuration.ps1')
. (Join-Path $script:CoreRoot 'lib\version.ps1')
. (Join-Path $script:CoreRoot 'lib\gallery.ps1')
. (Join-Path $script:CoreRoot 'lib\lock.ps1')

function New-TestLockMachine {
    param([string]$Modules, [string]$Lock)
    $root = New-TestMachine -Settings "    Modules = @{ $Modules }" -Lock $Lock
    New-Item -ItemType Directory -Path (Join-Path $root 'gallery') | Out-Null
    return $root
}

function Invoke-TestLock {
    param([string]$Root, [string[]]$Arguments, [hashtable]$Environment = @{})
    $Environment['NACRE_WINDOWS_GALLERY'] = Join-Path $Root 'gallery'
    return (Invoke-Nw -Root $Root -Arguments (@('lock') + $Arguments) -Environment $Environment)
}

function Read-TestLock {
    param([string]$Root)
    return (Read-NwJson (Join-Path $Root 'machine\nacre-windows.lock.json'))
}

function Read-TestPackage {
    param([string]$Root, [hashtable]$Package)
    $Package['Gallery'] = Join-Path $Root 'gallery'
    if (-not $Package.ContainsKey('Id')) { $Package['Id'] = 'Foo' }
    if (-not $Package.ContainsKey('Version')) { $Package['Version'] = '1.0' }
    return (Read-NwModulePackage (New-TestModulePackage @Package))
}

$script:TestCoreLock = "{ `"Core`": { `"Repo`": `"abnertu/nacre-windows`", `"Rev`": `"$('c' * 40)`", `"Sha256`": `"$('d' * 64)`" } }"

Test 'lock pins the canonical Id, the newest stable version, the checksum, editions and dependency ranges' {
    $root = New-TestLockMachine -Modules 'foo = $true' -Lock $script:TestCoreLock
    $gallery = Join-Path $root 'gallery'
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.0' | Out-Null
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '9.0' -File '9.0-beta1' | Out-Null
    $dependencies = '<group targetFramework="net6.0"><dependency id="Bar" version="[1.0, )" /></group><group><dependency id="bar" version="[1.0,2.0)" /><dependency id="Baz" /></group>'
    $path = New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.2.0' -ModuleVersion '1.2' -Dependencies $dependencies -ManifestLines "    CompatiblePSEditions = 'core'"
    Assert-Success (Invoke-TestLock -Root $root -Arguments @('foo'))

    $lock = Read-TestLock $root
    Assert-True ($lock['Core']['Rev'] -eq ('c' * 40)) 'lock dropped the Core key.'
    $id = @($lock['Modules'].Keys)
    Assert-True ($id.Count -eq 1 -and $id[0] -ceq 'Foo') "The pin key is '$($id -join ', ')'."
    $pin = $lock['Modules']['Foo']
    Assert-True ($pin['Version'] -eq '1.2.0' -and $pin['ModuleVersion'] -eq '1.2') "The pin is $($pin['Version']) / $($pin['ModuleVersion'])."
    Assert-True ($pin['Sha256'] -eq (Get-NwFileSha256 $path)) 'The pin has another checksum.'
    Assert-True (($pin['Editions'] -join ',') -ceq 'Core') "The editions are $($pin['Editions'] -join ',')."
    Assert-True ($pin['RequireLicenseAcceptance'] -eq $false) 'The license flag is set.'
    Assert-True (($pin['Dependencies']['Bar'] -join ' ') -ceq '[1.0, ) [1.0,2.0)') "Bar has $($pin['Dependencies']['Bar'] -join ' ')."
    Assert-True (($pin['Dependencies']['Baz'] -join ' ') -ceq '') 'Baz has a range.'
    Assert-True (@($pin['Dependencies'].Keys).Count -eq 2) 'The dependencies are not merged by Id.'
}

Test 'lock -Version pins one version by its nuspec text and checks the format first' {
    $root = New-TestLockMachine -Modules 'Foo = $true'
    New-TestModulePackage -Gallery (Join-Path $root 'gallery') -Id 'Foo' -Version '2.4.0' -File '2.4.0.0' | Out-Null
    New-TestModulePackage -Gallery (Join-Path $root 'gallery') -Id 'Foo' -Version '3.0' | Out-Null
    Assert-Success (Invoke-TestLock -Root $root -Arguments @('Foo', '-Version', '2.4'))
    Assert-True ((Read-TestLock $root)['Modules']['Foo']['Version'] -ceq '2.4.0') 'The pin does not hold the nuspec version.'
    Assert-Failure (Invoke-TestLock -Root $root -Arguments @('Foo', '-Version', '2.4.0-beta0')) 'is not a version of 2 to 4 numeric parts'
}

Test 'the package read normalizes the license flag and the editions' {
    $root = New-TestLockMachine -Modules 'Foo = $true'
    $license = @{ 'true' = $true; ' True ' = $true; '1' = $true; 'false' = $false; '0' = $false; '' = $false }

    foreach ($text in $license.Keys) {
        $package = Read-TestPackage $root @{ License = $text; File = [guid]::NewGuid().ToString('N') }
        Assert-True ($package.RequireLicenseAcceptance -eq $license[$text]) "'$text' gives $($package.RequireLicenseAcceptance)."
    }

    Assert-Throws { Read-TestPackage $root @{ License = 'yes' } } "requireLicenseAcceptance is 'yes'"
    $editions = @{ '' = 'Core,Desktop'; "    CompatiblePSEditions = @('Desktop', 'core', 'Core')" = 'Core,Desktop'; "    CompatiblePSEditions = 'desktop'" = 'Desktop' }

    foreach ($lines in $editions.Keys) {
        $package = Read-TestPackage $root @{ ManifestLines = $lines; File = [guid]::NewGuid().ToString('N') }
        Assert-True (($package.Editions -join ',') -ceq $editions[$lines]) "'$lines' gives $($package.Editions -join ',')."
    }

    Assert-Throws { Read-TestPackage $root @{ ManifestLines = '    CompatiblePSEditions = @()' } } 'empty CompatiblePSEditions'
    $package = Read-TestPackage $root @{ Id = 'foo'; NuspecId = 'Foo' }
    Assert-True ($package.Id -ceq 'Foo') 'The read lost the canonical Id.'
}

Test 'lock fails and keeps the lock for a package that does not match or a pin outside the format' {
    $cases = @(
        @{ Package = @{ NuspecId = 'Other' }; Pattern = "has the Id 'Other'" }
        @{ Package = @{ NuspecVersion = '1.1' }; Pattern = "1\.0 has the version '1\.1'" }
        @{ Package = @{ NoManifest = $true }; Pattern = 'no module manifest' }
        @{ Package = @{ Extra = @{ 'Second.nuspec' = '<package />' } }; Pattern = '2 root \.nuspec entries' }
        @{ Package = @{ ModuleVersion = '1.0-beta' }; Pattern = 'ModuleVersion must be a version' }
        @{ Package = @{ Dependencies = '<dependency id="Bar" version="[1.0-beta,)" />' }; Pattern = "not a version of 2 to 4" }
    )

    foreach ($case in $cases) {
        $root = New-TestLockMachine -Modules 'Foo = $true' -Lock $script:TestCoreLock
        $package = $case.Package
        $package['Gallery'] = Join-Path $root 'gallery'
        $package['Id'] = 'Foo'
        $package['Version'] = '1.0'
        New-TestModulePackage @package | Out-Null
        Assert-Failure (Invoke-TestLock -Root $root -Arguments @('Foo')) $case.Pattern
        Assert-True ((Read-TestText (Join-Path $root 'machine\nacre-windows.lock.json')) -eq $script:TestCoreLock) 'A failed lock changed the lock file.'
    }
}

Test 'lock fails and keeps the lock when the resulting pins miss a dependency range' {
    $bar = "`"Bar`": { `"Version`": `"2.0`", `"ModuleVersion`": `"2.0`", `"Sha256`": `"$('a' * 64)`", `"Editions`": [`"Core`", `"Desktop`"], `"RequireLicenseAcceptance`": false, `"Dependencies`": {} }"
    $lockText = "{ `"Modules`": { $bar } }"
    $root = New-TestLockMachine -Modules 'Foo = $true; Bar = $true' -Lock $lockText
    New-TestModulePackage -Gallery (Join-Path $root 'gallery') -Id 'Foo' -Version '1.0' -Dependencies '<dependency id="Bar" version="[1.0,2.0)" />' | Out-Null
    $result = Invoke-TestLock -Root $root -Arguments @('Foo')
    Assert-Failure $result "Module 'Foo' needs 'Bar' in \[1\.0,2\.0\)"
    Assert-Match $result.Output 'pinned at 2\.0'
    Assert-Match $result.Output '-Version'
    Assert-True ((Read-TestText (Join-Path $root 'machine\nacre-windows.lock.json')) -eq $lockText) 'A failed lock changed the lock file.'
}

Test 'a failed lock leaves no file in TEMP' {
    $root = New-TestLockMachine -Modules 'Foo = $true'
    $temp = Join-Path $root 'temp'
    New-Item -ItemType Directory -Path $temp | Out-Null
    $environment = @{ TEMP = $temp; TMP = $temp }
    New-TestModulePackage -Gallery (Join-Path $root 'gallery') -Id 'Foo' -Version '1.0' -NuspecId 'Other' | Out-Null
    Assert-Failure (Invoke-TestLock -Root $root -Arguments @('Foo') -Environment $environment) "has the Id 'Other'"
    Assert-True (@(Get-ChildItem -LiteralPath $temp -Force).Count -eq 0) 'A nuspec mismatch left a file in TEMP.'
    New-TestModulePackage -Gallery (Join-Path $root 'gallery') -Id 'Foo' -Version '1.0' -Manifest "@{ ModuleVersion = (Get-Date).ToString() }" | Out-Null
    Assert-Failure (Invoke-TestLock -Root $root -Arguments @('Foo') -Environment $environment) "Cannot read the manifest"
    Assert-True (@(Get-ChildItem -LiteralPath $temp -Force).Count -eq 0) 'A rejected manifest left a file in TEMP.'
}

Test 'lock leaves a dependency without a pin or not enabled to build' {
    $root = New-TestLockMachine -Modules 'Foo = $true; Baz = $false'
    New-TestModulePackage -Gallery (Join-Path $root 'gallery') -Id 'Foo' -Version '1.0' -Dependencies '<dependency id="Bar" version="[1.0]" /><dependency id="Baz" version="[1.0]" />' | Out-Null
    Assert-Success (Invoke-TestLock -Root $root -Arguments @('Foo'))

    $config = @{ Modules = @{ Foo = @{ Enable = $true }; Bar = @{ Enable = $true } } }

    $pins = @{
        Foo = @{ Version = '1.0'; Dependencies = @{ Bar = @('[1.0]') } }
        Bar = @{ Version = '2.0'; Dependencies = @{} }
    }

    Assert-True ((Get-NwDependencyRangeErrors -Config $config -Pins $pins -NewIds @()).Count -eq 0) 'A run without new module pins checked a range.'
    Assert-True ((Get-NwDependencyRangeErrors -Config $config -Pins $pins -NewIds @('bar')).Count -eq 1) 'A new dependency pin was not checked.'
}

Test 'lock checks the names and options before any pin' {
    $config = @{
        Sources = @{ Neovim = @{ Enable = $true }; Both = @{ Enable = $true }; Off = @{ Enable = $false } }
        Modules = @{ Foo = @{ Enable = $true }; both = @{ Enable = $true } }
    }

    Assert-Throws { Assert-NwLockArguments -Config $config -Names @('Foo') -Rev 'main' } '-Rev needs exactly one source name'
    Assert-Throws { Assert-NwLockArguments -Config $config -Names @('Neovim') -Version '1.0' } '-Version needs exactly one module name'
    Assert-Throws { Assert-NwLockArguments -Config $config -Names @('Neovim') -Rev 'main' -Version '1.0' } '-Rev and -Version cannot be used together'
    Assert-Throws { Assert-NwLockArguments -Config $config -Names @('BOTH') } "'BOTH' is both an enabled source and an enabled module"
    Assert-Throws { Assert-NwLockArguments -Config $config -Names @('Off') } "'Off' is not an enabled source or module"
    $targets = Assert-NwLockArguments -Config $config -Names @('foo') -Version '2.4'
    Assert-True ($targets.Count -eq 1 -and $targets[0].Kind -eq 'Module' -and $targets[0].Key -ceq 'Foo') 'The module target is wrong.'
}

Test 'a source revision resolves a ref to the pinned commit' {
    & {
        function Resolve-NwGitHubRev {
            param([string]$Repo, [string]$Ref)
            Assert-True ($Ref -ceq 'main') 'The source ref did not reach the resolver.'
            return ('c' * 40)
        }

        function Save-NwGitHubArchive {
            param([string]$Repo, [string]$Rev, [string]$OutFile)
            Assert-True ($Rev -ceq ('c' * 40)) 'The archive was requested by ref instead of commit.'
            [IO.File]::WriteAllText($OutFile, 'fixture archive')
        }

        $pin = Get-NwArchivePin -Repo 'fixture/source' -Rev 'main'
        Assert-True ($pin['Rev'] -ceq ('c' * 40)) 'The lock would store a mutable ref.'
    }
}

Test 'module lock preserves JSON strings and fractional metadata' {
    $stamp = '2026-01-01T03:04:05+05:30'
    $fixture = '{"Metadata":{"Recorded":"' + $stamp + '","Ratio":0.125}}'
    $root = New-TestLockMachine -Modules 'Foo = $true' -Lock $fixture
    New-TestModulePackage -Gallery (Join-Path $root 'gallery') -Id 'Foo' -Version '1.0' | Out-Null
    Assert-Success (Invoke-TestLock -Root $root -Arguments @('Foo'))
    $metadata = (Read-TestLock $root)['Metadata']
    Assert-True ($metadata['Recorded'] -is [string] -and $metadata['Recorded'] -ceq $stamp) 'lock changed the timestamp.'
    Assert-True ($metadata['Ratio'] -eq 0.125) 'lock changed the ratio.'
}

Test 'Read-NwLock rejects malformed module pins and reads locks without modules' {
    $root = New-TestRoot
    $path = Join-Path $root 'lock.json'
    $good = "`"Version`": `"2.4`", `"ModuleVersion`": `"2.4`", `"Sha256`": `"$('a' * 64)`", `"Editions`": [`"Core`"], `"RequireLicenseAcceptance`": false"

    $bad = @(
        "`"Modules`": null"
        "`"Modules`": []"
        "`"Modules`": { `"Foo`": `"1.0`" }"
        "`"Modules`": { `"Foo`": { $good, `"Dependencies`": { `"Bar`": [`"1.*`"] } } }"
        "`"Modules`": { `"Foo`": { $($good -replace '"2\.4", "ModuleVersion"', '2.4, "ModuleVersion"'), `"Dependencies`": {} } }"
        "`"Modules`": { `"Foo`": { $($good -replace 'a{64}', ('A' * 64)), `"Dependencies`": {} } }"
        "`"Modules`": { `"Foo`": { $($good -replace '"Core"', '"core"'), `"Dependencies`": {} } }"
        "`"Modules`": { `"Foo`": { $($good -replace '\["Core"\]', '["Desktop", "Core"]'), `"Dependencies`": {} } }"
        "`"Modules`": { `"Foo`": { $good, `"Dependencies`": { `"Bar`": [] } } }"
        "`"Modules`": { `"CON`": { $good, `"Dependencies`": {} } }"
        "`"Modules`": { `"Foo\n`": { $good, `"Dependencies`": {} } }"
        "`"Modules`": { `"Foo`": { $($good -replace 'a{64}', (('a' * 64) + '\n')), `"Dependencies`": {} } }"
    )

    foreach ($modules in $bad) {
        Set-TestFile $path "{ $modules }"
        Assert-Throws { Read-NwLock $path } 'invalid (module pin|lock)'
    }

    Set-TestFile $path "{ `"Modules`": { `"Foo`": { $good, `"Dependencies`": { `"Bar`": [`"(,3.0)`", `"[1.0, )`"] } } } }"
    Assert-True ((Read-NwLock $path)['Modules']['Foo']['Version'] -eq '2.4') 'A valid pin was rejected.'
    Set-TestFile $path '[{"Modules":{}}]'
    Assert-Throws { Read-NwLock $path } 'not a JSON object'
    Set-TestFile $path '{ "Sources": {} }'
    Assert-True ((Read-NwLock $path)['Modules'].Count -eq 0) 'A lock without Modules has modules.'
    Assert-True ((Read-NwLock (Join-Path $root 'none.json'))['Modules'].Count -eq 0) 'A missing lock has modules.'
}

Test 'the machine wrapper forwards an explicit Gallery module version' {
    $root = New-TestLockMachine -Modules 'Foo = $true'
    $gallery = Join-Path $root 'gallery'
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.0' | Out-Null
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '2.0' | Out-Null
    $wrapper = Join-Path $root 'machine\nacre.ps1'
    Copy-Item -LiteralPath (Join-Path $script:CoreRoot 'templates\machine\nacre.ps1') -Destination $wrapper
    Assert-Success (Invoke-TestScript -Root $root -Script $wrapper -Arguments @('lock', 'Foo', '-OverrideCore', $script:CoreRoot, '-Version', '1.0') -Environment @{ NACRE_WINDOWS_GALLERY = $gallery })
    Assert-True ((Read-TestLock $root)['Modules']['Foo']['Version'] -ceq '1.0') 'The wrapper pinned the latest version.'
    $similar = 'F' + [char]0x00AD + 'oo'
    Assert-Failure (Invoke-TestScript -Root $root -Script $wrapper -Arguments @('lock', $similar, '-OverrideCore', $script:CoreRoot) -Environment @{ NACRE_WINDOWS_GALLERY = $gallery }) 'not an enabled source or module'
}
