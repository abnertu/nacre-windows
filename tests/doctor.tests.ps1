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
