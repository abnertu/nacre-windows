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

Test 'update -Yes upgrades packages and skips prompts' {
    $root = New-TestMachine -WithoutRoleModules
    $result = Invoke-Nw -Root $root -Arguments @('update', '-Yes')
    Assert-Success $result
    Assert-Match $result.Log 'configuration-update\.winget --accept-configuration-agreements'
    Assert-NoMatch $result.Log '--interactive'
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

Test 'plan changes nothing and tolerates reported drift' {
    $root = New-TestMachine -WithoutRoleModules
    $result = Invoke-Nw -Root $root -Arguments @('plan') -Environment @{ NW_FAKE_WINGET_TEST_EXIT = '1' }
    Assert-Success $result
    Assert-Match $result.Log 'winget configure show -f'
    Assert-Match $result.Log 'winget configure test -f'
    Assert-Match $result.Log 'chezmoi diff --no-pager'
    Assert-NoMatch $result.Log 'winget configure -f'
    Assert-NoMatch $result.Log 'chezmoi apply'
    Assert-True (-not (Test-Path (Join-Path $root 'state\current.json'))) 'Plan recorded an artifact.'
}

Test 'plan -Yes accepts the agreement that a WinGet test asks for' {
    $root = New-TestMachine -WithoutRoleModules
    Assert-Success (Invoke-Nw -Root $root -Arguments @('plan', '-Yes'))
    Assert-Match (Read-TestText (Join-Path $root 'log.txt')) 'winget configure test -f .*configuration\.winget --accept-configuration-agreements'
}

Test 'doctor reports a configuration that changed after the last switch' {
    $root = New-TestMachine -WithoutRoleModules
    Assert-Success (Invoke-Nw -Root $root -Arguments @('switch', '-Yes'))
    Set-TestFile (Join-Path $root 'machine\home\dot_vimrc') "set number`n"
    Assert-Failure (Invoke-Nw -Root $root -Arguments @('doctor')) 'configuration changed since the last switch'
}

Test 'the machine wrapper runs the core from -OverrideCore and forwards arguments' {
    $root = New-TestMachine -WithoutRoleModules
    Copy-Item -LiteralPath (Join-Path $script:CoreRoot 'templates\machine\nacre.ps1') -Destination (Join-Path $root 'machine\nacre.ps1')
    $wrapper = Join-Path $root 'machine\nacre.ps1'
    $result = Invoke-TestScript -Root $root -Script $wrapper -Arguments @('update', '-OverrideCore', $script:CoreRoot, '-Yes')
    Assert-Success $result
    Assert-Match $result.Log 'configuration-update\.winget --accept-configuration-agreements'
}
