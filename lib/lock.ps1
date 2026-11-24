# Lock: each enabled source resolves to one GitHub commit and the SHA-256
# of its archive. The machine lock wins over the core defaults lock.
Set-StrictMode -Version Latest

$script:NwMachineLockName = 'nacre-windows.lock.json'

function Read-NwLock {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Sources = @{} } }
    $lock = Read-NwJson $Path
    if (-not ($lock -is [System.Collections.IDictionary])) { throw "'$Path' is not a JSON object." }
    if (-not $lock.ContainsKey('Sources') -or $null -eq $lock['Sources']) { $lock['Sources'] = @{} }

    foreach ($name in $lock['Sources'].Keys) {
        $pin = $lock['Sources'][$name]

        $valid = ($pin -is [System.Collections.IDictionary] -and
            [string]$pin['Repo'] -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and
            [string]$pin['Rev'] -match '^[0-9a-f]{40}$' -and
            [string]$pin['Sha256'] -match '^[0-9a-f]{64}$')

        if (-not $valid) { throw "'$Path' has an invalid pin for '$name'." }
    }

    return $lock
}

function Resolve-NwSourcePins {
    param([System.Collections.IDictionary]$Config, [string]$CoreRoot, [string]$MachineRoot, [string[]]$Names)
    $coreLock = Read-NwLock (Join-Path $CoreRoot 'sources.lock.json')
    $machineLock = Read-NwLock (Join-Path $MachineRoot $script:NwMachineLockName)
    $pins = @{}

    foreach ($name in (Get-NwSortedKeys $Config['Sources'])) {
        $source = $Config['Sources'][$name]
        if (-not $source['Enable'] -or $Names -notcontains $name) { continue }
        $pin = $null

        foreach ($lock in @($machineLock, $coreLock)) {
            if ($null -eq $pin -and $lock['Sources'].ContainsKey($name) -and $lock['Sources'][$name]['Repo'] -ieq $source['Repo']) {
                $pin = $lock['Sources'][$name]
            }
        }

        if ($null -eq $pin) {
            throw "Source '$name' ($($source['Repo'])) has no pin. Run: nacre-windows lock $name"
        }

        $pins[$name] = @{ Repo = $pin['Repo']; Rev = $pin['Rev']; Sha256 = $pin['Sha256'] }
    }

    return $pins
}

function Get-NwArchivePin {
    param([string]$Repo, [string]$Rev)
    if (-not $Rev) { $Rev = Resolve-NwGitHubRev -Repo $Repo }
    if ($Rev -notmatch '^[0-9a-f]{40}$') { $Rev = Resolve-NwGitHubRev -Repo $Repo -Ref $Rev }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('nacre-windows-' + [guid]::NewGuid().ToString('N') + '.tar.gz')

    try {
        Save-NwGitHubArchive -Repo $Repo -Rev $Rev -OutFile $file
        return @{ Repo = $Repo; Rev = $Rev; Sha256 = Get-NwFileSha256 $file }
    } finally {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
}

# Pin the named sources, or every enabled source, to the newest commit of
# their default branch, or to -Rev.
function Lock-NwSourcePins {
    param([System.Collections.IDictionary]$Config, [string]$LockPath, [string[]]$Names, [string]$Rev)
    $enabled = @(Get-NwSortedKeys $Config['Sources'] | Where-Object { $Config['Sources'][$_]['Enable'] })
    if (-not $Names -or $Names.Count -eq 0) { $Names = $enabled }
    if ($Rev -and $Names.Count -ne 1) { throw '-Rev needs exactly one source name.' }
    $lock = Read-NwLock $LockPath

    foreach ($name in $Names) {
        $match = @($enabled | Where-Object { $_ -ieq $name })
        if ($match.Count -ne 1) { throw "'$name' is not an enabled source. Enabled sources: $($enabled -join ', ')." }
        $key = $match[0]
        $repo = $Config['Sources'][$key]['Repo']
        $pin = Get-NwArchivePin -Repo $repo -Rev $Rev
        $previous = $null
        if ($lock['Sources'].ContainsKey($key)) { $previous = $lock['Sources'][$key]['Rev'] }
        $lock['Sources'][$key] = $pin

        if ($previous -eq $pin['Rev']) {
            Write-Host "$key is current at $($pin['Rev'])."
        } else {
            Write-Host "$key ($repo): $previous -> $($pin['Rev'])"
        }
    }

    Write-NwJson $LockPath $lock
}
