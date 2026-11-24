# Layering and validation, observed through the build output.

Test 'machine settings override role defaults key by key' {
    $root = New-TestMachine -Settings @"
    Packages = @{
        'Casey.Just'    = `$false
        'Notion.Notion' = `$true
    }
"@

    $document = Read-TestText (Join-Path (Invoke-TestBuild $root) 'configuration.winget')
    Assert-NoMatch $document "id: 'Casey\.Just'" 'after the machine withdrew it'
    Assert-Match $document "id: 'Notion\.Notion'" 'after the machine added it'
    Assert-Match $document "id: 'Git\.Git'" 'from the minimal role'
    Assert-Match $document "id: 'wez\.wezterm'" 'from the default workstation role'
}

Test 'the role selects the package set and its sources' {
    $root = New-TestMachine -Settings "    Role = 'minimal'"
    $artifact = Invoke-TestBuild $root
    $document = Read-TestText (Join-Path $artifact 'configuration.winget')
    Assert-Match $document "id: 'Neovim\.Neovim'"
    Assert-NoMatch $document "id: 'wez\.wezterm'" 'in the minimal role'
    $external = Read-TestText (Join-Path $artifact 'home\.chezmoiexternal.toml')
    Assert-Match $external '\[".config/nvim"\]'
    Assert-NoMatch $external 'wezterm' 'in the minimal role'
}

Test 'an unknown setting fails with its path and file' {
    $root = New-TestMachine -Settings "    Packages = @{ 'Git.Git' = @{ Enabled = `$true } }"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "Settings\.Packages\.Git\.Git\.Enabled is not a known setting"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "machine\.psd1"
}

Test 'a value of the wrong type fails' {
    $root = New-TestMachine -Settings '    ConfigHome = 1'
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) 'Settings\.ConfigHome must be a string'
}

Test 'a machine file without SchemaVersion fails' {
    $root = New-TestRoot
    Set-TestFile (Join-Path $root 'machine\machine.psd1') "@{ Role = 'minimal' }"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) 'must declare SchemaVersion'
}

Test 'an unknown role lists the known roles' {
    $root = New-TestMachine -Settings "    Role = 'server'"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) "Unknown role 'server'\. Known roles: .*workstation"
}

Test 'a machine file cannot run code' {
    $root = New-TestMachine -Settings "    Role = (Get-Date).ToString()"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) 'Cannot read'
}

Test 'Modules takes the shorthand and AcceptLicense' {
    $root = New-TestMachine -Settings "    Modules = @{ PSReadLine = `$false; 'Foo.Bar' = @{ Enable = `$false; AcceptLicense = `$true } }"
    Invoke-TestBuild $root | Out-Null
}

Test 'Modules rejects an unknown key, a missing Enable and a reserved or invalid name' {
    $cases = @{
        "Modules = @{ PSReadLine = @{ Enable = `$true; Version = '1.0' } }" = 'Settings\.Modules\.PSReadLine\.Version is not a known setting'
        "Modules = @{ Foo = @{ AcceptLicense = `$true } }"                  = 'Modules\.Foo needs Enable'
        "Modules = @{ 'Foo.' = `$false }"                                   = 'Modules\.Foo\. is not a valid module name'
        "Modules = @{ 'a..b' = `$false }"                                   = 'Modules\.a\.\.b is not a valid module name'
        "Modules = @{ 'COM0' = `$false }"                                   = 'Modules\.COM0 is not a valid module name'
        "Modules = @{ 'lpt0.x' = `$false }"                                 = 'Modules\.lpt0\.x is not a valid module name'
        "Modules = @{ 'Nul' = `$false }"                                    = 'Modules\.Nul is not a valid module name'
        "Modules = @{ 'Core' = `$false }"                                   = 'Modules\.Core is not a valid module name'
    }

    foreach ($settings in $cases.Keys) {
        $root = New-TestMachine -Settings "    $settings"
        Assert-Failure (Invoke-Nw -Root $root -Arguments @('build')) $cases[$settings]
    }

    $root = New-TestMachine -Settings "    Modules = @{ 'COM10' = `$false; 'Console' = `$false; 'Core.Utils' = `$false }"
    Invoke-TestBuild $root | Out-Null
}
