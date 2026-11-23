# Desktop workstation, the default: minimal and the WezTerm terminal.
@{
    Extends  = 'minimal'
    Packages = @{
        'wez.wezterm' = $true
    }
    Sources  = @{
        WezTerm = $true
    }
}