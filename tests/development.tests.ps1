# Development paths link a local worktree instead of a pinned archive.

function New-TestWorktree {
    param([string]$Root)
    $path = Join-Path $Root 'worktree'
    New-Item -ItemType Directory -Path (Join-Path $path '.git') -Force | Out-Null
    Set-TestFile (Join-Path $path 'init.lua') "-- worktree`n"
    return $path
}

Test 'a Development path replaces the archive with a junction to the worktree' {
    $root = New-TestRoot
    $worktree = New-TestWorktree $root
    Set-TestFile (Join-Path $root 'machine\machine.psd1') "@{ SchemaVersion = 1; Development = @{ Neovim = '$worktree' }; Modules = @{ PSReadLine = `$false } }"
    $artifact = Invoke-TestBuild $root
    $external = Read-TestText (Join-Path $artifact 'home\.chezmoiexternal.toml')
    Assert-NoMatch $external 'nvim' 'for a linked source'
    Assert-Match $external 'wezterm'

    Assert-Success (Invoke-Nw -Root $root -Arguments @('switch', '-Yes'))
    $link = Get-Item -LiteralPath (Join-Path $root 'home\.config\nvim') -Force
    Assert-True ([bool]($link.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) 'The target is not a link.'
    Assert-True (([string](@($link.Target)[0])).TrimEnd('\') -ieq $worktree) "The link points to '$($link.Target)'."
}

Test 'switch never applies an archive through a link and changes nothing' {
    $root = New-TestMachine -WithoutRoleModules
    $worktree = New-TestWorktree $root
    New-Item -ItemType Directory -Path (Join-Path $root 'home\.config') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $root 'home\.config\nvim') -Target $worktree | Out-Null
    $result = Invoke-Nw -Root $root -Arguments @('switch', '-Yes')
    Assert-Failure $result 'is a link to'
    Assert-NoMatch $result.Log 'winget configure -f' 'after the preflight failed'
    Assert-NoMatch $result.Log 'chezmoi apply'
    Assert-True (Test-Path (Join-Path $worktree '.git')) 'The worktree lost its .git directory.'
    Assert-True (-not (Test-Path (Join-Path $root 'state\pending.json'))) 'A failed preflight left a pending marker.'
}

Test 'switch keeps an existing directory where a Development link belongs' {
    $root = New-TestRoot
    $worktree = New-TestWorktree $root
    Set-TestFile (Join-Path $root 'machine\machine.psd1') "@{ SchemaVersion = 1; Development = @{ Neovim = '$worktree' }; Modules = @{ PSReadLine = `$false } }"
    Set-TestFile (Join-Path $root 'home\.config\nvim\init.lua') "-- existing`n"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('switch', '-Yes')) 'exists\. Move it away'
    Assert-Match (Read-TestText (Join-Path $root 'home\.config\nvim\init.lua')) 'existing'
}

Test 'a Development path must name an enabled source and be absolute' {
    $root = New-TestMachine -Settings "    Development = @{ Emacs = 'C:\x' }"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) 'Development\.Emacs names no enabled source'
    $root = New-TestMachine -Settings "    Development = @{ Neovim = 'relative\path' }"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) 'Development\.Neovim must be an absolute path'
}
