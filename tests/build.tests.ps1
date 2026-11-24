# Artifact content, identity and ownership rules.

Test 'equal inputs give one artifact and a changed input gives another' {
    $root = New-TestMachine -HomeFiles @{ 'dot_vimrc' = "set number`n" }
    $first = Invoke-TestBuild $root
    $second = Invoke-TestBuild $root
    Assert-True ($first -eq $second) "Two builds of one input differ: $first, $second."
    Set-TestFile (Join-Path $root 'machine\home\dot_vimrc') "set relativenumber`n"
    $third = Invoke-TestBuild $root
    Assert-True ($third -ne $first) 'A changed home file kept the artifact identifier.'
    Assert-Match (Read-TestText (Join-Path $third 'home\dot_vimrc')) 'relativenumber'
}

Test 'a machine file takes over a core file only after the core file is withdrawn' {
    $files = @{ 'dot_config/git/config' = "[user]`n    name = test`n" }
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

Test 'host-dependent chezmoi features are rejected' {
    foreach ($name in @('run_once_setup.ps1', 'dot_gitconfig.tmpl', 'symlink_dot_x', '.hidden')) {
        $root = New-TestMachine -HomeFiles @{ $name = "x`n" }
        Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) ([regex]::Escape($name))
    }
}

Test 'a home file inside a source directory is rejected' {
    $root = New-TestMachine -HomeFiles @{ 'dot_config/nvim/init.lua' = "-- x`n" }
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
