# Environment checks take the variables as input, so they run without the
# live registry.

. (Join-Path $script:CoreRoot 'lib\common.ps1')
. (Join-Path $script:CoreRoot 'lib\doctor.ps1')

Test 'environment checks report missing, repeated, empty and shadowed variables' {
    $exists = { param($Path) $Path -notlike '*missing*' }
    $machine = @{ Path = 'C:\Tools;C:\missing\bin'; PNPM_HOME = ''; TEMP = 'C:\T'; JAVA_HOME = 'C:\J' }
    $user = @{ Path = 'C:/tools/;C:\Other'; TEMP = 'C:\U'; JAVA_HOME = 'C:\K' }
    $issues = (Get-NwEnvironmentIssues -MachineVariables $machine -UserVariables $user -TestDirectory $exists) -join "`n"
    Assert-Match $issues 'Machine PATH entry does not exist: C:\\missing\\bin'
    Assert-Match $issues 'User PATH repeats a Machine PATH entry: C:/tools/'
    Assert-Match $issues "Machine variable 'PNPM_HOME' has an empty value"
    Assert-Match $issues "'JAVA_HOME' is defined in both Machine and User scopes"
    Assert-NoMatch $issues "'TEMP' is defined in both" 'for a name that Windows sets in both scopes'
    Assert-NoMatch $issues 'C:\\Other' 'for a healthy entry'
}

Test 'doctor checks the default path of installed editions with managed modules' {
    & {
        $script:NwModuleEditionFolders = @{ Core = 'PowerShell'; Desktop = 'WindowsPowerShell' }

        function Test-NwAlternateHome { return $alternate }

        function Get-NwDocumentsDirectory { return 'C:\Documents' }

        function Get-NwPolicyExecutable { param($Edition) return $Edition }

        function Get-NwDefaultModulePath {
            param($Executable)
            if ($Executable -eq 'Desktop') { return 'c:/documents/WindowsPowerShell/Modules/;C:\Other' }
            return 'C:\Other'
        }

        $alternate = $false
        $build = @{ Modules = @{ Fixture = @{ Editions = @('Desktop', 'Core') } } }
        $issues = @(Get-NwModulePathIssues -Build $build -Documents 'C:\Documents')
        Assert-True ($issues.Count -eq 1) 'Expected one missing module root.'
        Assert-Match ($issues -join '') 'PowerShell Core default PSModulePath does not include'
        $alternate = $true
        Assert-True (@(Get-NwModulePathIssues -Build $build -Documents 'C:\Documents').Count -eq 0) 'The alternate home probed the live editions.'
    }
}
