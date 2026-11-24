# Isolate the host probe and policy writer from persistent Windows policy.
. (Join-Path $script:CoreRoot 'lib\common.ps1')
. (Join-Path $script:CoreRoot 'lib\execution-policy.ps1')

function Invoke-TestPolicyDecision {
    param([hashtable]$Policies, [string]$Default = 'Restricted', [switch]$Apply)
    $writes = [System.Collections.Generic.List[string]]::new()

    function Get-ExecutionPolicy {
        param([string]$Scope)

        if ($Scope) {
            if ($Policies.ContainsKey($Scope)) { return $Policies[$Scope] }
            return 'Undefined'
        }

        foreach ($name in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
            if ($Policies.ContainsKey($name)) { return $Policies[$name] }
        }

        return $Default
    }

    function Set-ExecutionPolicy {
        param([string]$Scope, [string]$ExecutionPolicy, [switch]$Force)
        $writes.Add("$Scope $ExecutionPolicy $Force")
        $Policies[$Scope] = $ExecutionPolicy
    }

    return @{ Status = (& $script:NwExecutionPolicyProbe -Apply:$Apply); Writes = $writes }
}

Test 'only an effectively Restricted policy requests CurrentUser RemoteSigned' {
    $cases = @(
        @{ Policy = @{}; Default = 'Restricted'; Expected = 'Change' }
        @{ Policy = @{}; Default = 'RemoteSigned'; Expected = 'Current' }
        @{ Policy = @{ LocalMachine = 'Restricted'; CurrentUser = 'AllSigned' }; Default = 'Restricted'; Expected = 'Current' }
        @{ Policy = @{ LocalMachine = 'AllSigned'; CurrentUser = 'Restricted' }; Default = 'RemoteSigned'; Expected = 'Change' }
        @{ Policy = @{ UserPolicy = 'RemoteSigned'; CurrentUser = 'Restricted' }; Default = 'Restricted'; Expected = 'Current' }
        @{ Policy = @{ MachinePolicy = 'AllSigned'; UserPolicy = 'Restricted' }; Default = 'Restricted'; Expected = 'Current' }
        @{ Policy = @{ MachinePolicy = 'Restricted'; UserPolicy = 'Restricted' }; Default = 'RemoteSigned'; Expected = 'MachinePolicy' }
        @{ Policy = @{ UserPolicy = 'Restricted'; CurrentUser = 'RemoteSigned' }; Default = 'RemoteSigned'; Expected = 'UserPolicy' }
    )

    foreach ($case in $cases) {
        $result = Invoke-TestPolicyDecision -Policies $case.Policy -Default $case.Default
        Assert-True ($result.Status -ceq $case.Expected) "Expected $($case.Expected), got $($result.Status)."
        Assert-True ($result.Writes.Count -eq 0) 'The read-only probe wrote a policy.'
    }

    $result = Invoke-TestPolicyDecision -Policies @{ LocalMachine = 'Restricted' } -Apply
    Assert-True ($result.Status -eq 'Changed') 'The policy write was skipped.'
    Assert-True ($result.Writes.Count -eq 1 -and $result.Writes[0] -ceq 'CurrentUser RemoteSigned True') 'The write did not target CurrentUser RemoteSigned.'
    $result = Invoke-TestPolicyDecision -Policies @{ MachinePolicy = 'Restricted' } -Apply
    Assert-True ($result.Status -eq 'MachinePolicy' -and $result.Writes.Count -eq 0) 'The writer acted under a blocker.'
}

Test 'the policy stage checks blockers in every affected edition before writing' {
    $build = @{ Modules = @{ Foo = @{ Editions = @('Core', 'Desktop') } } }
    $writes = [System.Collections.Generic.List[string]]::new()
    $policies = @{ Core = 'UserPolicy'; Desktop = 'Change' }

    function Test-NwAlternateHome { return $false }

    function Get-NwPolicyExecutable { param($Edition) return "$Edition.exe" }

    function Invoke-NwPolicyProbe {
        param($Edition, $Executable, [switch]$Apply)
        Assert-True ($Executable -eq "$Edition.exe") 'The edition used the wrong executable.'

        if ($Apply) {
            $writes.Add($Edition)
            return 'Changed'
        }

        return $policies[$Edition]
    }

    Assert-Throws { Set-NwModulePolicies $build } 'Core Group Policy \(UserPolicy\) is Restricted'
    Assert-True ($writes.Count -eq 0) 'The stage changed one edition before checking the other.'
    $policies.Core = 'Current'
    Set-NwModulePolicies $build
    Assert-True ($writes.Count -eq 1 -and $writes[0] -ceq 'Desktop') 'The stage changed an unaffected edition.'
}

Test 'the policy stage skips alternate homes and artifacts with no modules' {
    $alternate = $true

    function Test-NwAlternateHome { return $alternate }

    function Get-NwPolicyExecutable { throw 'The stage probed a host.' }

    Set-NwModulePolicies @{ Modules = @{ Foo = @{ Editions = @('Core') } } }
    $alternate = $false
    Set-NwModulePolicies @{ Modules = @{} }
}

Test 'the native probe distinguishes a preview from a write' {
    $original = $script:NwExecutionPolicyProbe

    $script:NwExecutionPolicyProbe = {
        param([switch]$Apply)
        if ($Apply) { return 'Changed' }
        return 'Change'
    }

    try {
        $preview = Invoke-NwPolicyProbe -Edition $PSEdition -Executable $script:Shell
        $write = Invoke-NwPolicyProbe -Edition $PSEdition -Executable $script:Shell -Apply
        Assert-True ($preview -ceq 'Change' -and $write -ceq 'Changed') 'The child host did not receive the requested probe mode.'
    } finally {
        $script:NwExecutionPolicyProbe = $original
    }
}

Test 'plan and doctor report policy changes and switch stops at a policy blocker' {
    . (Join-Path $script:CoreRoot 'lib\deploy.ps1')
    . (Join-Path $script:CoreRoot 'lib\doctor.ps1')
    $root = New-TestRoot
    $messages = [System.Collections.Generic.List[string]]::new()
    $proposed = 'Switch sets the PowerShell Desktop CurrentUser execution policy to RemoteSigned.'
    $blocker = Get-NwPolicyBlocker -Edition Core -Scope UserPolicy

    function Invoke-NwBuild {
        return @{ Path = $root; Id = 'test'; Links = @{}; Config = @{ Doctor = @{ Commands = @{} } } }
    }

    function Get-NwModuleState { return @{ Blocking = @(); Warnings = @(); Installs = @(); Documents = $null } }

    function Get-NwSourceIssues { return , @() }

    function Get-NwConfigHomeState { return @{ State = 'alternate' } }

    function Get-NwStateRoot { return $root }

    function Get-NwEnvironmentIssues { return , @() }

    function Test-NwCommand { return $false }

    function Invoke-NwNative { $script:NwExitCode = 0 }

    function Get-NwPackageDrift { return @{ Lines = @(); Failure = $null } }

    function Write-Host { param($Message) $messages.Add($Message) }

    function Write-Warning { param($Message) $messages.Add($Message) }

    function Set-NwModulePolicies { throw 'Unexpected policy write.' }

    function Invoke-NwDeployment { throw 'Deployment started before policy preflight finished.' }

    function Get-NwModulePolicyChanges {
        @{ Blocking = $false; Message = $proposed }
        @{ Blocking = $true; Message = $blocker }
    }

    Invoke-NwPlan -CoreRoot $root -MachineRoot $root
    Assert-True ($messages.Contains($proposed)) 'Plan omitted the proposed policy change.'
    Assert-True ($messages.Contains("Switch stops: $blocker")) 'Plan omitted the policy blocker.'
    $messages.Clear()
    Assert-Throws { Invoke-NwDoctor -CoreRoot $root -MachineRoot $root } 'Doctor found'
    Assert-True ($messages.Contains($proposed) -and $messages.Contains($blocker)) 'Doctor omitted a policy issue.'
    Assert-Throws { Invoke-NwSwitch -CoreRoot $root -MachineRoot $root } '(?s)Switch changed nothing:.*Core Group Policy'
}
