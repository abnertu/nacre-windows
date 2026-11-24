# Core defaults. Roles and machine.psd1 override them key by key.
@{
    SchemaVersion = 1
    Role          = 'workstation'

    # Home-relative config root. Switch declares it as XDG_CONFIG_HOME, which
    # Neovim and WezTerm read on Windows.
    ConfigHome    = '.config'

    # '<WinGet id>' = @{ Enable = $true; Version = '<pin>'; Hold = $true; Source = 'winget' }
    # or the shorthand '<WinGet id>' = $true / $false. Hold keeps an installed
    # package at its version during update; a missing one still installs.
    Packages      = @{}

    # Core home files by target path. '<target>' = $false withdraws one.
    Files         = @{}

    # Config directories from a pinned GitHub commit. Target is a directory
    # under ConfigHome. The archive owns that whole directory.
    Sources       = @{
        Neovim  = @{ Enable = $false; Repo = 'abnertu/orbit.nvim'; Target = 'nvim' }
        WezTerm = @{ Enable = $false; Repo = 'Orbit-Lua/wezterm'; Target = 'wezterm' }
    }

    # '<Source>' = '<absolute path>' links a local worktree instead of the pin.
    Development   = @{}

    # PowerShell Gallery modules: '<Gallery id>' = @{ Enable = $true; AcceptLicense = $true }
    # or the shorthand '<Gallery id>' = $true / $false. lock pins each version.
    Modules       = @{
        PSReadLine = @{ Enable = $false }
    }

    # Commands that doctor expects in exactly one PATH directory.
    Doctor        = @{
        Commands = @{ git = $true; chezmoi = $true }
    }
}
