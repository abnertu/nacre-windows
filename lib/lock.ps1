# Lock: each enabled source resolves to one GitHub commit and the SHA-256
# of its archive. Each enabled module resolves to one Gallery package
# version and its SHA-256. The machine lock wins over the core defaults
# lock. Load common, configuration, version and gallery first.
Set-StrictMode -Version Latest

$script:NwMachineLockName = 'nacre-windows.lock.json'

function Test-NwSortedUniqueStrings {
    param($Value)
    if (-not ($Value -is [System.Array]) -or $Value.Count -eq 0) { return $false }

    foreach ($item in $Value) { if (-not ($item -is [string])) { return $false } }
    [string[]]$sorted = @($Value)
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)

    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if (-not ($sorted[$i] -ceq $Value[$i])) { return $false }
        if ($i -gt 0 -and $sorted[$i] -ceq $sorted[$i - 1]) { return $false }
    }

    return $true
}

# Return the errors of one module pin. The Id and ModuleVersion become path
# parts, so this check keeps every module path inside its root.
function Get-NwModulePinErrors {
    param([string]$Id, $Pin)
    $errors = @()
    if (-not (Test-NwModuleName $Id)) { $errors += 'the Id is not a valid module name' }
    if (-not ($Pin -is [System.Collections.IDictionary])) { return , @($errors + 'the pin is not a map') }

    foreach ($key in @($Pin.Keys)) {
        if (@('Version', 'ModuleVersion', 'Sha256', 'Editions', 'RequireLicenseAcceptance', 'Dependencies') -notcontains $key) {
            $errors += "'$key' is not a pin field"
        }
    }

    foreach ($key in @('Version', 'ModuleVersion')) {
        if (-not (Test-NwVersionText $Pin[$key])) { $errors += "$key must be a version string of 2 to 4 numeric parts" }
    }

    if (-not ($Pin['Sha256'] -is [string]) -or $Pin['Sha256'] -cnotmatch '^[0-9a-f]{64}\z') {
        $errors += 'Sha256 must be 64 lowercase hexadecimal digits'
    }

    $editions = $Pin['Editions']

    if (-not (Test-NwSortedUniqueStrings $editions) -or @($editions | Where-Object { $_ -cnotmatch '\A(?:Core|Desktop)\z' }).Count -gt 0) {
        $errors += "Editions must be a sorted array of 'Core' and 'Desktop'"
    }

    if (-not ($Pin['RequireLicenseAcceptance'] -is [bool])) { $errors += 'RequireLicenseAcceptance must be a bool' }
    $dependencies = $Pin['Dependencies']

    if (-not ($dependencies -is [System.Collections.IDictionary])) {
        $errors += 'Dependencies must be a map'
    } else {
        foreach ($name in @($dependencies.Keys)) {
            if (-not (Test-NwModuleName ([string]$name))) { $errors += "the dependency '$name' is not a valid module name" }
            $ranges = $dependencies[$name]

            if (-not (Test-NwSortedUniqueStrings $ranges)) {
                $errors += "the ranges of '$name' must be a sorted array of unique strings"
                continue
            }

            foreach ($range in $ranges) {
                try { ConvertTo-NwVersionRange $range | Out-Null } catch { $errors += "the range '$range' of '$name': $($_.Exception.Message)" }
            }
        }
    }

    return , $errors
}

function Read-NwLock {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Sources = @{}; Modules = @{} } }
    $lock = Read-NwJson $Path
    if (-not ($lock -is [System.Collections.IDictionary])) { throw "'$Path' is not a JSON object." }
    if (-not $lock.ContainsKey('Sources') -or $null -eq $lock['Sources']) { $lock['Sources'] = @{} }
    if (-not $lock.ContainsKey('Modules')) { $lock['Modules'] = @{} }
    if (-not ($lock['Sources'] -is [System.Collections.IDictionary])) { throw "'$Path' has an invalid lock: Sources is not a map." }
    if (-not ($lock['Modules'] -is [System.Collections.IDictionary])) { throw "'$Path' has an invalid lock: Modules is not a map." }

    foreach ($name in $lock['Sources'].Keys) {
        $pin = $lock['Sources'][$name]

        $valid = ($pin -is [System.Collections.IDictionary] -and
            [string]$pin['Repo'] -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and
            [string]$pin['Rev'] -match '^[0-9a-f]{40}$' -and
            [string]$pin['Sha256'] -match '^[0-9a-f]{64}$')

        if (-not $valid) { throw "'$Path' has an invalid pin for '$name'." }
    }

    foreach ($id in $lock['Modules'].Keys) {
        $errors = Get-NwModulePinErrors -Id $id -Pin $lock['Modules'][$id]
        if ($errors.Count -gt 0) { throw "'$Path' has an invalid module pin for '$id': $($errors -join '; ')." }
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

# The key of a map that equals the name, ignoring case, or $null.
function Find-NwKey {
    param([System.Collections.IDictionary]$Map, [string]$Name)
    foreach ($key in $Map.Keys) { if ([string]$key -ieq $Name) { return [string]$key } }
    return $null
}

# Effective module pins, keyed by the canonical Id: each lock in the list
# wins over the locks after it.
function Get-NwEffectiveModulePins {
    param([System.Collections.IDictionary[]]$Locks)
    $pins = @{}

    foreach ($lock in $Locks) {
        foreach ($id in $lock['Modules'].Keys) {
            if (-not (Find-NwKey $pins $id)) { $pins[[string]$id] = $lock['Modules'][$id] }
        }
    }

    return $pins
}

function Test-NwModuleEnabled {
    param([System.Collections.IDictionary]$Config, [string]$Name)
    $key = Find-NwKey $Config['Modules'] $Name
    return ($null -ne $key -and [bool]$Config['Modules'][$key]['Enable'])
}

# The pin of each enabled module, keyed by the canonical pin Id.
function Resolve-NwModulePins {
    param([System.Collections.IDictionary]$Config, [string]$CoreRoot, [string]$MachineRoot)
    $coreLock = Read-NwLock (Join-Path $CoreRoot 'sources.lock.json')
    $machineLock = Read-NwLock (Join-Path $MachineRoot $script:NwMachineLockName)
    $effective = Get-NwEffectiveModulePins @($machineLock, $coreLock)
    $pins = @{}

    foreach ($name in (Get-NwSortedKeys $Config['Modules'])) {
        if (-not $Config['Modules'][$name]['Enable']) { continue }
        $id = Find-NwKey $effective $name
        if (-not $id) { throw "Module '$name' has no pin. Run: nacre-windows lock $name" }
        $pins[$id] = Copy-NwValue $effective[$id]
    }

    return $pins
}

# Check the dependency ranges between enabled, pinned modules where the
# module or its dependency is in NewIds. Other cases are left to build.
function Get-NwDependencyRangeErrors {
    param([System.Collections.IDictionary]$Config, [System.Collections.IDictionary]$Pins, [string[]]$NewIds)
    $errors = @()

    foreach ($id in (Get-NwSortedKeys $Pins)) {
        if (-not (Test-NwModuleEnabled $Config $id)) { continue }
        $dependencies = $Pins[$id]['Dependencies']

        foreach ($name in (Get-NwSortedKeys $dependencies)) {
            $dependency = Find-NwKey $Pins $name
            if (-not $dependency -or -not (Test-NwModuleEnabled $Config $name)) { continue }
            if (-not (@($NewIds | Where-Object { $_ -ieq $id -or [string]::Equals($_, $name, [StringComparison]::OrdinalIgnoreCase) }))) { continue }
            $version = $Pins[$dependency]['Version']
            $ranges = @($dependencies[$name])
            $outside = @($ranges | Where-Object { -not (Test-NwVersionInRange (ConvertTo-NwVersion $version) (ConvertTo-NwVersionRange $_)) })

            if ($outside.Count -gt 0) {
                $errors += "Module '$id' needs '$dependency' in $($ranges -join ' and '), but '$dependency' is pinned at $version. Pin one of the two with -Version."
            }
        }
    }

    return , $errors
}

# Check the names and options of lock before any pin. Returns the targets:
# @{ Kind = 'Source' | 'Module'; Key }.
function Assert-NwLockArguments {
    param([System.Collections.IDictionary]$Config, [string[]]$Names, [string]$Rev, [string]$Version)
    $sources = @(Get-NwSortedKeys $Config['Sources'] | Where-Object { $Config['Sources'][$_]['Enable'] })
    $modules = @(Get-NwSortedKeys $Config['Modules'] | Where-Object { $Config['Modules'][$_]['Enable'] })
    $targets = @()

    if (-not $Names -or $Names.Count -eq 0) {
        $targets += @($sources | ForEach-Object { @{ Kind = 'Source'; Key = $_ } })
        $targets += @($modules | ForEach-Object { @{ Kind = 'Module'; Key = $_ } })
    }

    foreach ($name in $Names) {
        $source = @($sources | Where-Object { [string]::Equals($_, $name, [StringComparison]::OrdinalIgnoreCase) })
        $module = @($modules | Where-Object { [string]::Equals($_, $name, [StringComparison]::OrdinalIgnoreCase) })
        if ($source.Count -gt 0 -and $module.Count -gt 0) { throw "'$name' is both an enabled source and an enabled module." }
        if ($source.Count -gt 0) { $targets += @{ Kind = 'Source'; Key = $source[0] }; continue }
        if ($module.Count -gt 0) { $targets += @{ Kind = 'Module'; Key = $module[0] }; continue }
        throw "'$name' is not an enabled source or module. Enabled sources: $($sources -join ', '). Enabled modules: $($modules -join ', ')."
    }

    if ($Rev -and $Version) { throw '-Rev and -Version cannot be used together.' }
    $one = ($null -ne $Names -and $Names.Count -eq 1)
    if ($Rev -and (-not $one -or $targets[0].Kind -ne 'Source')) { throw '-Rev needs exactly one source name.' }

    if ($Version) {
        if (-not $one -or $targets[0].Kind -ne 'Module') { throw '-Version needs exactly one module name.' }
        if (-not (Test-NwVersionText $Version)) { throw "-Version '$Version' is not a version of 2 to 4 numeric parts, such as '2.4.5'." }
    }

    return , $targets
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

# Download one module package and pin it: @{ Id; Pin }.
function Get-NwModulePin {
    param([string]$Name, [string]$Version)
    if (-not $Version) { $Version = Get-NwGalleryLatestVersion -Name $Name }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('nacre-windows-' + [guid]::NewGuid().ToString('N') + '.nupkg')

    try {
        Save-NwGalleryPackage -Name $Name -Version $Version -OutFile $file
        $package = Read-NwModulePackage -Path $file -Label "$Name $Version"
        if (-not [string]::Equals($package.Id, $Name, [StringComparison]::OrdinalIgnoreCase)) { throw "The Gallery package of '$Name' has the Id '$($package.Id)'." }

        if (-not (Test-NwVersionText $package.Version) -or (ConvertTo-NwVersion $package.Version) -ne (ConvertTo-NwVersion $Version)) {
            throw "The Gallery package of '$Name' $Version has the version '$($package.Version)'."
        }

        $pin = @{
            Version                  = $package.Version
            ModuleVersion            = $package.ModuleVersion
            Sha256                   = Get-NwFileSha256 $file
            Editions                 = $package.Editions
            RequireLicenseAcceptance = $package.RequireLicenseAcceptance
            Dependencies             = $package.Dependencies
        }

        $errors = Get-NwModulePinErrors -Id $package.Id -Pin $pin
        if ($errors.Count -gt 0) { throw "The Gallery package of '$Name' gives an invalid pin: $($errors -join '; ')." }
        return @{ Id = $package.Id; Pin = $pin }
    } finally {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
}

function Invoke-NwLockWrite {
    param([string]$Path, [scriptblock]$Update)
    # Keep this mutex name in sync with the standalone machine wrapper.
    $full = [IO.Path]::GetFullPath($Path)
    $key = Get-NwTextSha256 $full.ToUpperInvariant()
    $mutex = [Threading.Mutex]::new($false, "Global\nacre-windows-lock-$key")

    try {
        try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }

        try {
            & $Update
        } finally {
            $mutex.ReleaseMutex()
        }
    } finally {
        $mutex.Dispose()
    }
}

function Write-NwLockFile {
    param([string]$Path, [string]$Text)
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')

    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))

        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
}

# Pin the named sources and modules, or every enabled one. A source takes
# the newest commit of its default branch or -Rev. A module takes the
# newest stable version or -Version. LowerLockPaths are the locks that the
# target lock wins over, for the dependency check.
function Lock-NwPins {
    param(
        [System.Collections.IDictionary]$Config,
        [string]$LockPath,
        [string[]]$LowerLockPaths = @(),
        [string[]]$Names,
        [string]$Rev,
        [string]$Version
    )

    $targets = Assert-NwLockArguments -Config $Config -Names $Names -Rev $Rev -Version $Version

    Invoke-NwLockWrite -Path $LockPath -Update {
        $lock = Read-NwLock $LockPath
        $newIds = @()
        $messages = @()

        foreach ($target in $targets) {
            $key = $target.Key

            if ($target.Kind -eq 'Source') {
                $repo = $Config['Sources'][$key]['Repo']
                $pin = Get-NwArchivePin -Repo $repo -Rev $Rev
                $previous = $null
                if ($lock['Sources'].ContainsKey($key)) { $previous = $lock['Sources'][$key]['Rev'] }
                $lock['Sources'][$key] = $pin

                if ($previous -eq $pin['Rev']) {
                    $messages += "$key is current at $($pin['Rev'])."
                } else {
                    $messages += "$key ($repo): $previous -> $($pin['Rev'])"
                }

                continue
            }

            $module = Get-NwModulePin -Name $key -Version $Version
            $previous = $null
            $old = Find-NwKey $lock['Modules'] $module.Id

            if ($old) {
                $previous = $lock['Modules'][$old]['Version']
                # A case-insensitive map keeps the old spelling of a key.
                $lock['Modules'].Remove($old)
            }

            $lock['Modules'][$module.Id] = $module.Pin
            $newIds += $module.Id

            if ($previous -eq $module.Pin['Version']) {
                $messages += "$($module.Id) is current at $previous."
            } else {
                $messages += "$($module.Id): $previous -> $($module.Pin['Version'])"
            }
        }

        [System.Collections.IDictionary[]]$locks = @(@($lock) + @($LowerLockPaths | ForEach-Object { Read-NwLock $_ }))
        $errors = Get-NwDependencyRangeErrors -Config $Config -Pins (Get-NwEffectiveModulePins $locks) -NewIds $newIds
        if ($errors.Count -gt 0) { throw ("lock changed nothing:`n  " + ($errors -join "`n  ")) }
        Write-NwLockFile $LockPath ((ConvertTo-NwJson $lock) + "`n")
        foreach ($message in $messages) { Write-Host $message }
    }
}
