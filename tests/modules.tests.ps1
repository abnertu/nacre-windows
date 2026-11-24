# Module checks use isolated home, state, package, and native command fixtures.
. (Join-Path $script:CoreRoot 'lib\common.ps1')
. (Join-Path $script:CoreRoot 'lib\version.ps1')
. (Join-Path $script:CoreRoot 'lib\build.ps1')
. (Join-Path $script:CoreRoot 'lib\modules.ps1')

Test 'module path overlap compares Windows path components ordinally' {
    $directory = 'C:\Fixture'
    $similar = 'C:\Fix' + [char]0x00AD + 'ture'
    Assert-True (-not (Test-NwModulePathOverlap @($similar) @($directory))) 'Distinct Windows directories overlap.'
    Assert-True (-not (Test-NwModulePathOverlap @("$similar\child") @($directory))) 'A similar sibling path overlaps.'
    Assert-True (Test-NwModulePathOverlap @('c:\FIXTURE\child') @($directory)) 'A case-insensitive descendant was missed.'
}

Test 'Documents must be fully qualified only when modules are enabled' {
    foreach ($documents in @('', 'Documents', 'C:Documents', '\Documents', '\\server', '\\?\C:\Documents')) {
        $state = Get-NwModuleState -Build @{ Modules = @{ Fixture = @{} } } -Documents $documents
        Assert-Match ($state.Blocking -join ' ') 'fully qualified'
        Assert-True ($state.Installs.Count -eq 0) 'Invalid Documents had module installs.'
        $state = Get-NwModuleState -Build @{ Modules = @{} } -Documents $documents
        Assert-True ($state.Blocking.Count -eq 0) 'A module-free machine required Documents.'
    }
}

Test 'path resolution preserves intermediate junction aliases and uncreated leaves' {
    $root = New-TestRoot
    $physical = Join-Path $root 'physical'
    $firstLink = Join-Path $root 'first'
    $secondLink = Join-Path $root 'second'
    New-NwDirectory $physical
    New-Item -ItemType Junction -Path $secondLink -Target $physical | Out-Null
    New-Item -ItemType Junction -Path $firstLink -Target $secondLink | Out-Null

    try {
        $missing = Join-Path $firstLink 'absent\file'
        $resolved = Resolve-NwPath $missing
        Assert-True ($resolved.Candidates -contains $missing) 'The lexical path was lost.'
        Assert-True ($resolved.Candidates -contains (Join-Path $secondLink 'absent\file')) 'The intermediate alias was lost.'
        Assert-True ($resolved.Path -eq (Join-Path $physical 'absent\file')) 'The final alias was not resolved.'
        Assert-True ($null -eq $resolved.Item) 'A missing item was returned.'

        [IO.Directory]::Delete($physical)
        $dangling = Resolve-NwPath $missing
        Assert-True ($dangling.Path -eq (Join-Path $physical 'absent\file') -and $null -eq $dangling.Item) 'A dangling link lost its eventual path.'
        Assert-Throws { Resolve-NwPath $firstLink -RequireLinkTargets } 'links to missing path'
    } finally {
        [IO.Directory]::Delete($firstLink)
        [IO.Directory]::Delete($secondLink)
    }
}

function New-ModuleFixture {
    param(
        [hashtable]$Package = @{},
        [string[]]$Editions = @('Core', 'Desktop'),
        [string]$ExtraSettings = '',
        [hashtable]$HomeFiles = @{},
        [switch]$WrongChecksum
    )

    $settings = @('    Modules = @{ Fixture = $true; DisabledFixture = $false; PSReadLine = $false }', $ExtraSettings)
    $root = New-TestMachine -Settings ($settings -join [Environment]::NewLine) -HomeFiles $HomeFiles
    $arguments = @{ Gallery = (Join-Path $root 'gallery'); Id = 'Fixture'; Version = '1.0' }
    foreach ($key in $Package.Keys) { $arguments[$key] = $Package[$key] }
    $path = New-TestModulePackage @arguments
    $hash = Get-NwFileSha256 $path
    if ($WrongChecksum) { $hash = 'e' * 64 }

    $pin = @{
        Version                  = '1.0'
        ModuleVersion            = '1.0'
        Sha256                   = $hash
        Editions                 = $Editions
        RequireLicenseAcceptance = $false
        Dependencies             = @{}
    }

    Write-NwJson (Join-Path $root 'machine\nacre-windows.lock.json') @{ Modules = @{ Fixture = $pin } }
    return $root
}

function Get-ModuleFixtureEnvironment {
    param([string]$Root)
    $temporary = Join-Path $Root 'temp'
    New-NwDirectory $temporary
    return @{ NACRE_WINDOWS_GALLERY = (Join-Path $Root 'gallery'); TEMP = $temporary; TMP = $temporary; NW_FAKE_WINGET_EXPORT = (New-TestInstalledExport $Root) }
}

function Invoke-TestModuleSwitch {
    param([string]$Root)
    return (Invoke-Nw -Root $Root -Arguments @('switch', '-Yes') -Environment (Get-ModuleFixtureEnvironment $Root))
}

function Assert-ModulePreflightFailure {
    param([string]$Root, [string]$Pattern)
    $result = Invoke-TestModuleSwitch $Root
    Assert-Failure $result $Pattern
    Assert-NoMatch $result.Log 'winget configure -f|chezmoi apply'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Root 'state\pending.json'))) 'A failed preflight left pending.json.'
}

Test 'switch installs selected editions with decoded paths and retries offline' {
    foreach ($coreOnly in @($false, $true)) {
        $payloadName = '.sign' + [char]0x00AD + 'ature.p7s'
        $package = @{ Extra = @{ 'docs/with%20space.txt' = 'payload'; '.signature.p7s' = 'signature'; '.sign%C2%ADature.p7s' = 'payload' } }
        $editions = @('Core', 'Desktop')

        if ($coreOnly) {
            $package.ManifestLines = "    CompatiblePSEditions = @('Core')"
            $editions = @('Core')
        }

        $root = New-ModuleFixture -Package $package -Editions $editions
        Assert-Success (Invoke-TestModuleSwitch $root)
        $core = Join-Path $root 'home\Documents\PowerShell\Modules\Fixture\1.0'
        $desktop = Join-Path $root 'home\Documents\WindowsPowerShell\Modules\Fixture\1.0'
        Assert-True (Test-Path -LiteralPath (Join-Path $core 'Fixture.psd1') -PathType Leaf) 'Core install has no manifest.'
        Assert-True ((Read-TestText (Join-Path $core 'docs\with space.txt')) -eq 'payload') 'The encoded file was not installed.'
        Assert-True ((Read-TestText (Join-Path $core $payloadName)) -eq 'payload') 'A similar payload was mistaken for NuGet metadata.'
        Assert-True ((Test-Path -LiteralPath $desktop -PathType Container) -eq (-not $coreOnly)) 'The Desktop install did not match its edition.'

        foreach ($metadata in @('_rels', 'package', 'Fixture.nuspec', '[Content_Types].xml', '.signature.p7s')) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $core $metadata))) "NuGet metadata '$metadata' was installed."
        }

        $gallery = Join-Path $root 'gallery'
        [IO.Directory]::Move($gallery, (Join-Path $root 'offline-gallery'))
        Assert-Success (Invoke-TestModuleSwitch $root)
    }
}

Test 'failed module packages leave no staged version or temporary file' {
    $cases = @(
        @{ Checksum = $true; Error = 'SHA-256 mismatch' }
        @{ Package = @{ NuspecId = 'Other' }; Error = 'differs from pin' }
        @{ Package = @{ NuspecId = ('Fix' + [char]0x00AD + 'ture'); NoManifest = $true; Extra = @{ 'Fixture.psd1' = "@{ ModuleVersion = '1.0' }"; 'Fix%C2%ADture.psd1' = "@{ ModuleVersion = '1.0' }" } }; Error = 'differs from pin' }
        @{ Package = @{ NuspecVersion = '2.0' }; Error = 'differs from pin' }
        @{ Package = @{ ModuleVersion = '1.0.0' }; Error = 'ModuleVersion' }
        @{ Package = @{ ModuleVersion = ('1.' + [char]0x00AD + '0') }; Error = 'ModuleVersion' }
    )

    foreach ($entry in @('/rooted.txt', 'D:/rooted.txt', 'docs/../../escape.txt', 'docs/%2e%2e/escape.txt', 'docs/data.txt:stream', 'docs/AUX.txt', 'docs/odd./file', 'docs/odd /file')) {
        $cases += @{ Package = @{ Extra = @{ $entry = 'invalid' } }; Error = 'Invalid module package entry' }
    }

    foreach ($case in $cases) {
        $package = @{}
        if ($case.ContainsKey('Package')) { $package = $case.Package }
        $root = New-ModuleFixture -Package $package -WrongChecksum:($case.ContainsKey('Checksum'))
        $result = Invoke-TestModuleSwitch $root
        Assert-Failure $result $case.Error
        Assert-NoMatch $result.Log 'chezmoi apply'
        $versions = Join-Path $root 'home\Documents\PowerShell\Modules\Fixture'

        if (Test-Path -LiteralPath $versions) {
            Assert-True (@(Get-ChildItem -LiteralPath $versions -Force).Count -eq 0) 'A failed install left a version or staging directory.'
        }

        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'temp') -Force).Count -eq 0) 'A failed install left files in TEMP.'
    }
}

Test 'switch removes only staging directories of enabled modules and preserves link targets' {
    $root = New-ModuleFixture
    $moduleDirectory = Join-Path $root 'home\Documents\PowerShell\Modules\Fixture'
    $staging = Join-Path $moduleDirectory ('1.0.tmp-' + ('a' * 32))
    $linkedStage = Join-Path $moduleDirectory ('1.0.tmp-' + ('b' * 32))
    $notOwned = Join-Path $moduleDirectory ('1.0.tmp-' + ('C' * 32))
    $disabled = Join-Path $root ('home\Documents\PowerShell\Modules\DisabledFixture\1.0.tmp-' + ('d' * 32))
    $outside = Join-Path $root 'outside'
    $sentinel = Join-Path $outside 'retained'
    New-NwDirectory $staging
    New-NwDirectory $notOwned
    New-NwDirectory $disabled
    Set-TestFile $sentinel 'retained'
    $nested = Join-Path $staging 'nested'
    New-Item -ItemType Junction -Path $nested -Target $outside | Out-Null
    New-Item -ItemType Junction -Path $linkedStage -Target $outside | Out-Null

    try {
        Assert-Success (Invoke-TestModuleSwitch $root)
        Assert-True (-not (Test-Path -LiteralPath $staging)) 'A stale staging directory remains.'
        Assert-True (-not (Test-Path -LiteralPath $linkedStage)) 'A stale linked staging directory remains.'
        Assert-True (Test-Path -LiteralPath $notOwned) 'Switch removed a directory outside the staging pattern.'
        Assert-True (Test-Path -LiteralPath $disabled) 'Switch removed an unmanaged staging directory.'
        Assert-True ((Read-TestText $sentinel) -eq 'retained') 'Switch removed data through a staging link.'
    } finally {
        foreach ($link in @($nested, $linkedStage)) {
            if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
        }
    }
}

Test 'switch rejects files, links and incomplete manifests along the module install path' {
    $version = 'home\Documents\PowerShell\Modules\Fixture\1.0'

    $cases = @(
        @{ Directory = $version; Error = 'without a regular' }
        @{ Directory = "$version\Fixture.psd1"; Error = 'without a regular' }
        @{ Link = "$version\Fixture.psd1"; Error = 'without a regular' }
        @{ File = 'home\Documents\PowerShell'; Error = 'is a file or link' }
        @{ Link = 'home\Documents\PowerShell'; Error = 'is a file or link' }
        @{ Link = $version; Error = 'is a file or link' }
        @{ File = 'home\Documents'; Error = 'is a file' }
        @{ Link = 'home\Documents'; Dangling = $true; Error = 'links to missing path' }
    )

    foreach ($case in $cases) {
        $root = New-ModuleFixture
        $link = $null
        if ($case.ContainsKey('Directory')) { New-NwDirectory (Join-Path $root $case.Directory) }
        if ($case.ContainsKey('File')) { Set-TestFile (Join-Path $root $case.File) 'file' }

        if ($case.ContainsKey('Link')) {
            $link = Join-Path $root $case.Link
            $target = Join-Path $root 'target'
            New-NwDirectory $target
            New-NwDirectory (Split-Path -Parent $link)
            New-Item -ItemType Junction -Path $link -Target $target | Out-Null
            if ($case.ContainsKey('Dangling')) { [IO.Directory]::Delete($target) }
        }

        try {
            Assert-ModulePreflightFailure -Root $root -Pattern $case.Error
        } finally {
            if ($link) { [IO.Directory]::Delete($link) }
        }
    }
}

Test 'switch rejects home files and source declarations on either side of module ownership' {
    foreach ($homeFile in @('Documents/PowerShell', 'Documents/PowerShell/Modules/Fixture/custom')) {
        $root = New-ModuleFixture -HomeFiles @{ $homeFile = 'conflict' }
        Assert-ModulePreflightFailure -Root $root -Pattern 'overlaps the module directory'
    }

    foreach ($sourcePath in @('Documents\PowerShell', 'Documents\PowerShell\Modules\Fixture\owned')) {
        $sourceTarget = Split-Path -Leaf $sourcePath
        $configHome = (Split-Path -Parent $sourcePath).Replace('\', '/')

        $source = @(
            "    ConfigHome = '$configHome'",
            ('    Sources = @{{ Neovim = @{{ Enable = $true; Target = ''{0}'' }} }}' -f $sourceTarget)
        ) -join [Environment]::NewLine

        $root = New-ModuleFixture -ExtraSettings $source
        Assert-ModulePreflightFailure -Root $root -Pattern 'overlaps the module directory'

        $worktree = Join-Path $root 'worktree'
        New-NwDirectory $worktree
        $settingsPath = Join-Path $root 'machine\machine.psd1'
        $settings = (Read-TestText $settingsPath).TrimEnd().TrimEnd('}')
        $development = "    Development = @{ Neovim = '$worktree' }" + [Environment]::NewLine + '}'
        Set-TestFile $settingsPath ($settings + $development)
        Assert-ModulePreflightFailure -Root $root -Pattern 'overlaps the module directory'
    }

    $root = New-ModuleFixture -ExtraSettings (@(
            "    ConfigHome = 'Documents/PowerShell/Modules/Unmanaged'",
            '    Sources = @{ Neovim = @{ Enable = $true; Target = ''owned'' } }'
        ) -join [Environment]::NewLine)

    Assert-Success (Invoke-TestModuleSwitch $root)
}

Test 'switch supports redirected Documents and catches overlaps through a second alias' {
    $root = New-ModuleFixture
    $physical = Join-Path $root 'redirected'
    $documents = Join-Path $root 'home\Documents'
    $alias = Join-Path $root 'home\other'
    New-NwDirectory $physical
    New-Item -ItemType Junction -Path $documents -Target $physical | Out-Null
    New-Item -ItemType Junction -Path $alias -Target $physical | Out-Null

    try {
        Assert-Success (Invoke-TestModuleSwitch $root)
        Assert-True (Test-Path -LiteralPath (Join-Path $physical 'PowerShell\Modules\Fixture\1.0\Fixture.psd1')) 'Switch ignored the Documents target.'
        Set-TestFile (Join-Path $root 'machine\files\other\PowerShell\Modules\Fixture\conflict') 'conflict'
        Set-TestFile (Join-Path $root 'log.txt') ''
        Assert-ModulePreflightFailure -Root $root -Pattern 'overlaps the module directory'
    } finally {
        [IO.Directory]::Delete($documents)
        [IO.Directory]::Delete($alias)
    }
}

Test 'switch rejects a source target that leaves the module tree through a junction' {
    $root = New-ModuleFixture -ExtraSettings (@(
            "    ConfigHome = 'Documents/PowerShell/Modules/Fixture/other'",
            '    Sources = @{ Neovim = @{ Enable = $true; Target = ''archive'' } }'
        ) -join [Environment]::NewLine)

    $link = Join-Path $root 'home\Documents\PowerShell\Modules\Fixture\other'
    $outside = Join-Path $root 'outside'
    New-NwDirectory (Split-Path -Parent $link)
    New-NwDirectory $outside
    New-Item -ItemType Junction -Path $link -Target $outside | Out-Null

    try {
        Assert-ModulePreflightFailure -Root $root -Pattern 'overlaps the module directory'
    } finally {
        [IO.Directory]::Delete($link)
    }
}

Test 'plan and doctor report missing modules, blocking issues and advisory warnings' {
    $root = New-ModuleFixture -ExtraSettings '    Doctor = @{ Commands = @{ git = $false; chezmoi = $false; nvim = $false; node = $false; pwsh = $false } }'
    $environment = Get-ModuleFixtureEnvironment $root
    $moduleDirectory = Join-Path $root 'home\Documents\PowerShell\Modules\Fixture'

    $plan = Invoke-Nw -Root $root -Arguments @('plan', '-Yes') -Environment $environment
    Assert-Success $plan
    Assert-Match $plan.Output 'Switch installs PowerShell module .Fixture. version .1.0.'
    Assert-Match $plan.Output 'PowerShell\\Modules\\Fixture'
    Assert-Match $plan.Output 'WindowsPowerShell\\Modules\\Fixture'
    Assert-NoMatch $plan.Log 'winget configure -f|chezmoi apply'
    Assert-True (-not (Test-Path -LiteralPath $moduleDirectory)) 'Plan installed a module.'
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('doctor', '-Yes') -Environment $environment) 'is missing from'

    Assert-Success (Invoke-TestModuleSwitch $root)
    $staging = Join-Path $moduleDirectory ('1.0.tmp-' + ('a' * 32))
    New-NwDirectory $staging
    Set-TestFile (Join-Path $moduleDirectory '1.0.0\Fixture.psd1') "@{ ModuleVersion = '1.0.0' }"
    $plan = Invoke-Nw -Root $root -Arguments @('plan', '-Yes') -Environment $environment
    Assert-Success $plan
    Assert-Match $plan.Output 'Stale module staging directory'
    Assert-Match $plan.Output 'has a higher version .1.0.0.'
    $doctor = Invoke-Nw -Root $root -Arguments @('doctor', '-Yes') -Environment $environment
    Assert-Success $doctor
    Assert-Match $doctor.Output 'Stale module staging directory'
    Assert-Match $doctor.Output 'has a higher version .1.0.0.'
    Assert-True (Test-Path -LiteralPath $staging) 'Plan or doctor deleted stale staging.'

    Remove-Item -LiteralPath (Join-Path $moduleDirectory '1.0\Fixture.psd1')
    $plan = Invoke-Nw -Root $root -Arguments @('plan', '-Yes') -Environment $environment
    Assert-Success $plan
    Assert-Match $plan.Output 'Switch stops: .*'
    Assert-Match $plan.Output 'without a regular'
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('doctor', '-Yes') -Environment $environment) 'without a regular'
}
