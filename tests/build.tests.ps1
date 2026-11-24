# Artifact content, identity and ownership rules.

Test 'equal inputs give one artifact and a changed input gives another' {
    $root = New-TestMachine -HomeFiles @{ '.vimrc' = "set number`n" }
    $first = Invoke-TestBuild $root
    $second = Invoke-TestBuild $root
    Assert-True ($first -eq $second) "Two builds of one input differ: $first, $second."
    Set-TestFile (Join-Path $root 'machine\files\.vimrc') "set relativenumber`n"
    $third = Invoke-TestBuild $root
    Assert-True ($third -ne $first) 'A changed home file kept the artifact identifier.'
    Assert-Match (Read-TestText (Join-Path $third 'home\dot_vimrc')) 'relativenumber'
}

Test 'a machine file takes over a core file only after the core file is withdrawn' {
    $files = @{ '.config/git/config' = "[user]`n    name = test`n" }
    $root = New-TestMachine -HomeFiles $files
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "'\.config/git/config' has two owners"

    $root = New-TestMachine -HomeFiles $files -Settings "    Files = @{ '.config/git/config' = `$false }"
    $artifact = Invoke-TestBuild $root
    Assert-Match (Read-TestText (Join-Path $artifact 'home\dot_config\git\config')) 'name = test'
}

Test 'withdrawing a file that the core does not have fails' {
    $root = New-TestMachine -Settings "    Files = @{ '.config/none' = `$false }"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "names no core file"
}

Test 'target names that look like chezmoi attributes stay literal' {
    $root = New-TestMachine -HomeFiles @{
        '.config/x' = "x`n"
        'private_y' = "y`n"
        'z'         = ''
        'run_w'     = ''
        'd.tmpl/f'  = "f`n"
        'g.tmpl'    = "g`n"
    }

    $artifact = Invoke-TestBuild $root

    $sources = @(Get-ChildItem -LiteralPath (Join-Path $artifact 'home') -Recurse -File | ForEach-Object {
            $_.FullName.Substring((Join-Path $artifact 'home').Length + 1).Replace('\', '/')
        } | Sort-Object)

    $expected = @('.chezmoiexternal.toml', 'd.tmpl/f', 'dot_config/x', 'dot_config/git/config', 'dot_config/powershell/profile.ps1', 'empty_literal_run_w', 'empty_z', 'g.tmpl.literal', 'literal_private_y') | Sort-Object
    Assert-True (($sources -join ',') -eq ($expected -join ',')) "Source names: $($sources -join ', ')"
    $receipt = Read-TestText (Join-Path $artifact 'receipt.json')

    foreach ($target in @('.config/x', 'private_y', 'z', 'run_w', 'd.tmpl/f', 'g.tmpl')) {
        Assert-Match $receipt ('"Target":\s*"' + [regex]::Escape($target) + '"')
    }
}

Test 'chezmoi special files and the old home directory are rejected' {
    $root = New-TestMachine -HomeFiles @{ '.chezmoiignore' = "x`n" }
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) 'chezmoi special files'

    $root = New-TestMachine
    Set-TestFile (Join-Path $root 'machine\home\dot_vimrc') "x`n"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "old home file directory.*'files'"
}

Test 'a home file inside a source directory is rejected' {
    $root = New-TestMachine -HomeFiles @{ '.config/nvim/init.lua' = "-- x`n" }
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "inside '\.config/nvim', which a source owns"
}

Test 'a replaced source repo needs a machine pin, which the artifact then uses' {
    $settings = "    Sources = @{ Neovim = @{ Repo = 'someone/nvim' } }"
    $root = New-TestMachine -Settings $settings
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "Source 'Neovim' \(someone/nvim\) has no pin"

    $rev = 'a' * 40
    $sha = 'b' * 64
    $lock = "{ `"Sources`": { `"Neovim`": { `"Repo`": `"someone/nvim`", `"Rev`": `"$rev`", `"Sha256`": `"$sha`" } } }"
    $root = New-TestMachine -Settings $settings -Lock $lock
    $external = Read-TestText (Join-Path (Invoke-TestBuild $root) 'home\.chezmoiexternal.toml')
    Assert-Match $external "github\.com/someone/nvim/archive/$rev\.tar\.gz"
    Assert-Match $external "checksum\.sha256 = `"$sha`""
}

Test 'ConfigHome moves every source target' {
    $root = New-TestMachine -Settings "    ConfigHome = 'cfg'"
    $external = Read-TestText (Join-Path (Invoke-TestBuild $root) 'home\.chezmoiexternal.toml')
    Assert-Match $external '\["cfg/nvim"\]'
    Assert-Match $external '\["cfg/wezterm"\]'
}

Test 'a pinned version and a hold are kept, and only other packages use the latest on update' {
    $root = New-TestMachine -Settings "    Packages = @{ 'Neovim.Neovim' = @{ Enable = `$true; Version = '0.11.5' }; 'sharkdp.fd' = @{ Enable = `$true; Hold = `$true } }"
    $artifact = Invoke-TestBuild $root
    $normal = Read-TestText (Join-Path $artifact 'configuration.winget')
    $update = Read-TestText (Join-Path $artifact 'configuration-update.winget')
    Assert-Match $normal "id: 'Neovim\.Neovim'\n      source: 'winget'\n      version: '0\.11\.5'"
    Assert-NoMatch $normal 'useLatest'
    Assert-Match $update "id: 'Git\.Git'\n      source: 'winget'\n      useLatest: true"
    Assert-Match $update "id: 'Neovim\.Neovim'\n      source: 'winget'\n      version: '0\.11\.5'\n"
    Assert-Match $update "id: 'sharkdp\.fd'\n      source: 'winget'\n(  -|$)" 'for a held package'
}

function New-TestModulePin {
    param([string]$Version = '1.0', [string]$Editions = '"Core", "Desktop"', [string]$Dependencies = '', [string]$License = 'false')
    return "{ `"Version`": `"$Version`", `"ModuleVersion`": `"$Version`", `"Sha256`": `"$('e' * 64)`", `"Editions`": [$Editions], `"RequireLicenseAcceptance`": $License, `"Dependencies`": { $Dependencies } }"
}

function Read-TestReceipt {
    param([string]$Artifact)
    return (ConvertFrom-Json (Read-TestText (Join-Path $Artifact 'receipt.json')))
}

Test 'both roles enable the PSReadLine pin and a machine can withdraw it' {
    $lock = ConvertFrom-Json (Read-TestText (Join-Path $script:CoreRoot 'sources.lock.json'))

    foreach ($role in @('minimal', 'workstation')) {
        $root = New-TestMachine -Settings "    Role = '$role'"
        $receipt = Read-TestReceipt (Invoke-TestBuild $root)
        Assert-True ($receipt.Modules.PSReadLine.Sha256 -ceq $lock.Modules.PSReadLine.Sha256) "$role did not use the core PSReadLine pin."
        $root = New-TestMachine -Settings "    Role = '$role'" -WithoutRoleModules
        $receipt = Read-TestReceipt (Invoke-TestBuild $root)
        Assert-True ($null -eq $receipt.Modules.PSObject.Properties['PSReadLine']) "$role ignored the machine withdrawal."
    }
}

Test 'build records module pins, and the machine pin wins over the core pin' {
    $root = New-TestMachine -Settings '    Modules = @{ PSReadLine = $true }'
    $receipt = Read-TestReceipt (Invoke-TestBuild $root)
    Assert-True ($receipt.Modules.PSReadLine.Version -eq '2.4.5') 'The receipt lacks the core pin of PSReadLine.'

    $lock = "{ `"Modules`": { `"PSReadLine`": $(New-TestModulePin -Version '2.3.6') } }"
    $root = New-TestMachine -Settings '    Modules = @{ PSReadLine = $true }' -Lock $lock
    $receipt = Read-TestReceipt (Invoke-TestBuild $root)
    Assert-True ($receipt.Modules.PSReadLine.Version -eq '2.3.6') 'The machine pin did not win.'

    $lock = "{ `"Modules`": { `"Foo`": $(New-TestModulePin -License 'true') } }"
    $root = New-TestMachine -Settings '    Modules = @{ Foo = @{ Enable = $true; AcceptLicense = $true } }' -Lock $lock
    Assert-True ((Read-TestReceipt (Invoke-TestBuild $root)).Modules.Foo.RequireLicenseAcceptance) 'The license pin is not recorded.'
}

Test 'build rejects a missing pin, an unaccepted license and inconsistent dependencies' {
    $bar = New-TestModulePin -Version '2.0' -Editions '"Desktop"'
    $license = New-TestModulePin -License 'true'
    $any = New-TestModulePin -Dependencies '"Bar": [""]'
    $two = New-TestModulePin -Editions '"Desktop"' -Dependencies '"Bar": ["(,2.0)", "[1.0, )"]'
    $above = New-TestModulePin -Editions '"Desktop"' -Dependencies '"Bar": ["[3.0,)"]'
    $core = New-TestModulePin -Dependencies '"bar": ["[2.0]"]'

    $cases = @(
        @{ Modules = 'Foo = $true'; Pins = ''; Pattern = "Module 'Foo' has no pin\. Run: nacre-windows lock Foo" }
        @{ Modules = 'Foo = $true'; Pins = "`"Foo`": $license"; Pattern = 'Modules\.Foo\.AcceptLicense' }
        @{ Modules = 'Foo = $true'; Pins = "`"Foo`": $any"; Pattern = "'Bar', which is not a declared module" }
        @{ Modules = 'Foo = $true; Bar = $false'; Pins = "`"Foo`": $any"; Pattern = "'Bar', which is disabled" }
        @{ Modules = 'Foo = $true; Bar = $true'; Pins = "`"Foo`": $two, `"Bar`": $bar"; Pattern = "needs 'Bar' in \(,2\.0\) and \[1\.0, \)" }
        @{ Modules = 'Foo = $true; Bar = $true'; Pins = "`"Foo`": $above, `"Bar`": $bar"; Pattern = 'pinned at 2\.0' }
        @{ Modules = 'Foo = $true; Bar = $true'; Pins = "`"Foo`": $core, `"Bar`": $bar"; Pattern = "needs 'Bar' for Core" }
    )

    foreach ($case in $cases) {
        $root = New-TestMachine -Settings "    Modules = @{ $($case.Modules) }" -Lock "{ `"Modules`": { $($case.Pins) } }"
        Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) $case.Pattern
    }

    $root = New-TestMachine -Lock '{ "Modules": [] }'
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) 'invalid lock'
}

Test 'build keys a module pin by its canonical Id for any spelling of the setting' {
    foreach ($name in @('common', 'configuration', 'version', 'gallery', 'lock', 'build')) {
        . (Join-Path (Join-Path $script:CoreRoot 'lib') "$name.ps1")
    }

    $ids = @()

    foreach ($spelling in @('psreadline', 'PSReadLine')) {
        $root = New-TestMachine -Settings "    Modules = @{ $spelling = `$true }"
        $saved = $env:NACRE_WINDOWS_STATE
        $env:NACRE_WINDOWS_STATE = Join-Path $root 'state'

        try {
            $build = Invoke-NwBuild -CoreRoot $script:CoreRoot -MachineRoot (Join-Path $root 'machine')
        } finally {
            $env:NACRE_WINDOWS_STATE = $saved
        }

        $keys = @($build.Modules.Keys)
        Assert-True ($keys.Count -eq 1 -and $keys[0] -ceq 'PSReadLine') "The build result keys the pin as '$($keys -join ', ')'."
        $keys = @($build.Receipt['Modules'].Keys)
        Assert-True ($keys.Count -eq 1 -and $keys[0] -ceq 'PSReadLine') "The receipt keys the pin as '$($keys -join ', ')'."
        $ids += $build.Id
    }

    Assert-True ($ids[0] -eq $ids[1]) "The spellings give two artifacts: $($ids -join ', ')."
}
