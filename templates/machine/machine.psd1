# Machine configuration for nacre-windows. Every setting is optional except
# SchemaVersion: an unset setting keeps the role or core default.
@{
    SchemaVersion = 1

    # minimal or workstation. Default: workstation.
    # Role = 'workstation'

    # Home-relative config root, declared as XDG_CONFIG_HOME. Default: '.config'.
    # ConfigHome = '.config'

    # Add a package, pin or hold it, or withdraw a role default.
    # Packages = @{
    #     'Obsidian.Obsidian'    = $true
    #     'Neovim.Neovim'        = @{ Enable = $true; Version = '0.11.5' }
    #     'wez.wezterm'          = @{ Enable = $true; Hold = $true }
    #     'Microsoft.PowerShell' = $false
    # }

    # Withdraw a core home file so that home/ can own its target.
    # Files = @{ '.config/git/config' = $false }

    # Replace or withdraw a pinned config source. Pin a new Repo with:
    #   .\nacre.ps1 lock <Source>
    # Sources = @{
    #     Neovim  = @{ Repo = 'you/your-nvim' }
    #     WezTerm = $false
    # }

    # Link a local worktree instead of the pinned source.
    # Development = @{ Neovim = 'C:\Users\you\codebase\your-nvim' }

    # Commands that doctor expects in exactly one PATH directory.
    # Doctor = @{ Commands = @{ pnpm = $true } }
}
