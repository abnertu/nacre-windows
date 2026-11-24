# Core tools, shell and development tools: Git, the home file engine,
# PowerShell 7 and Neovim with its tool chain.
@{
    Packages = @{
        'Git.Git'                     = $true
        'twpayne.chezmoi'             = $true
        'Microsoft.PowerShell'        = $true
        'GitHub.cli'                  = $true
        'Neovim.Neovim'               = $true
        'tree-sitter.tree-sitter-cli' = $true
        'DEVCOM.Lua'                  = $true
        'OpenJS.NodeJS.LTS'           = $true
        'Casey.Just'                  = $true
        'Starship.Starship'           = $true
        'BurntSushi.ripgrep.MSVC'     = $true
        'sharkdp.fd'                  = $true
        'junegunn.fzf'                = $true
    }
    Sources  = @{
        Neovim = $true
    }
    Modules  = @{
        PSReadLine = $true
    }
    Doctor   = @{
        Commands = @{ nvim = $true; node = $true; pwsh = $true }
    }
}
