# Plan, switch and doctor against fake winget and chezmoi.

Test 'switch applies the built artifact and records it' {
    $root = New-TestMachine -WithoutRoleModules
    $artifact = Invoke-TestBuild $root
    $result = Invoke-Nw -Root $root -Arguments @('switch')
    Assert-Success $result
    $escaped = [regex]::Escape($artifact)
    Assert-Match $result.Log "winget configure -f $escaped\\configuration\.winget"
    Assert-Match $result.Log "chezmoi apply --source $escaped\\home --destination .* --interactive"
    $current = Read-TestText (Join-Path $root 'state\current.json')
    Assert-Match $current ([regex]::Escape((Split-Path -Leaf $artifact)))
    Assert-True (-not (Test-Path (Join-Path $root 'state\pending.json'))) 'The pending marker remains after success.'
}

Test 'upgrade system -Yes upgrades packages and skips prompts' {
    $root = New-TestMachine -WithoutRoleModules
    $result = Invoke-Nw -Root $root -Arguments @('upgrade', 'system', '-Yes')
    Assert-Success $result
    Assert-Match $result.Log 'configuration-update\.winget --accept-configuration-agreements'
    Assert-NoMatch $result.Log '--interactive'

    Assert-Failure (Invoke-Nw -Root $root -Arguments @('update')) 'does not belong to the set'

    foreach ($arguments in @(@('upgrade'), @('upgrade', 'everything'))) {
        Assert-Failure (Invoke-Nw -Root $root -Arguments $arguments) 'Usage: upgrade system'
    }
}

Test 'a declined WinGet agreement applies nothing and exits cleanly' {
    $root = New-TestMachine -WithoutRoleModules
    $result = Invoke-Nw -Root $root -Arguments @('switch') -Environment @{ NW_FAKE_WINGET_EXIT = '-1978286069' }
    Assert-Success $result
    Assert-Match $result.Output 'agreement was declined'
    Assert-NoMatch $result.Log 'chezmoi apply'
    Assert-True (-not (Test-Path (Join-Path $root 'state\pending.json'))) 'A declined switch kept the pending marker.'
    Assert-True (-not (Test-Path (Join-Path $root 'state\current.json'))) 'A declined switch recorded an artifact.'
}

Test 'a failed package stage stops before the home stage and doctor reports it' {
    $root = New-TestMachine -WithoutRoleModules
    $result = Invoke-Nw -Root $root -Arguments @('switch') -Environment @{ NW_FAKE_WINGET_EXIT = '3' }
    Assert-Failure $result 'exit code 3'
    Assert-NoMatch $result.Log 'chezmoi apply'
    Assert-True (Test-Path (Join-Path $root 'state\pending.json')) 'No pending marker after a failed switch.'
    Assert-True (-not (Test-Path (Join-Path $root 'state\current.json'))) 'A failed switch recorded an artifact.'
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('doctor')) 'did not finish'
}

Test 'plan reports package drift from one winget export and changes nothing' {
    $settings = "    Role = 'minimal'`n    Packages = @{ 'Fixture.Pinned' = @{ Enable = `$true; Version = '2.0' }; 'Fixture.Missing' = `$true }"
    $root = New-TestMachine -WithoutRoleModules -Settings $settings
    $export = Join-Path $root 'export.json'
    Set-TestFile $export '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Fixture.Pinned","Version":"1.0"}]}]}'
    $result = Invoke-Nw -Root $root -Arguments @('plan') -Environment @{ NW_FAKE_WINGET_EXPORT = $export }
    Assert-Success $result
    Assert-Match $result.Output '~ package Fixture\.Pinned 1\.0, declared 2\.0'
    Assert-Match $result.Output '\+ package Fixture\.Missing \(missing'
    Assert-Match $result.Log 'winget export -o'
    Assert-NoMatch $result.Log 'winget configure'
    Assert-Match $result.Log 'chezmoi diff --no-pager'
    Assert-NoMatch $result.Log 'chezmoi apply'
    Assert-True (-not (Test-Path (Join-Path $root 'state\current.json'))) 'Plan recorded an artifact.'
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('doctor') -Environment @{ NW_FAKE_WINGET_EXPORT = $export }) 'Package drift: \+ package Fixture\.Missing'
}

Test 'doctor reports a configuration that changed after the last switch' {
    $root = New-TestMachine -WithoutRoleModules
    Assert-Success (Invoke-Nw -Root $root -Arguments @('switch', '-Yes'))
    Set-TestFile (Join-Path $root 'machine\files\.vimrc') "set number`n"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('doctor')) 'configuration changed since the last switch'
}

Test 'the machine wrapper runs the core from -OverrideCore and forwards arguments' {
    $root = New-TestMachine -WithoutRoleModules
    Copy-Item -LiteralPath (Join-Path $script:CoreRoot 'templates\machine\nacre.ps1') -Destination (Join-Path $root 'machine\nacre.ps1')
    $wrapper = Join-Path $root 'machine\nacre.ps1'
    $result = Invoke-TestScript -Root $root -Script $wrapper -Arguments @('upgrade', 'system', '-OverrideCore', $script:CoreRoot, '-Yes')
    Assert-Success $result
    Assert-Match $result.Log 'configuration-update\.winget --accept-configuration-agreements'
}
