# Configuration: core defaults, then the role chain, then the machine file.
# A later layer overrides scalars and merges maps key by key. Maps keyed by
# an identifier let a layer disable a default with Enable = $false.
Set-StrictMode -Version Latest

$script:NwSchemaVersion = 1

# Leaf types: 'bool', 'int', 'string'. A map with '*' takes any key.
$script:NwSchema = @{
    SchemaVersion = 'int'
    Role          = 'string'
    ConfigHome    = 'string'
    Packages      = @{ '*' = @{ Enable = 'bool'; Version = 'string'; Hold = 'bool'; Source = 'string' } }
    Files         = @{ '*' = 'bool' }
    Sources       = @{ '*' = @{ Enable = 'bool'; Repo = 'string'; Target = 'string' } }
    # Source name -> absolute path of a local worktree, linked instead of the pin.
    Development   = @{ '*' = 'string' }
    # Gallery Id -> a PowerShell Gallery module, pinned in the lock files.
    Modules       = @{ '*' = @{ Enable = 'bool'; AcceptLicense = 'bool' } }
    Doctor        = @{ Commands = @{ '*' = 'bool' } }
}

$script:NwPackageSources = @('winget', 'msstore')

function Import-NwDataFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file '$Path'." }

    try {
        # Import-PowerShellDataFile evaluates no code; it accepts constants only.
        return (Import-PowerShellDataFile -LiteralPath $Path)
    } catch {
        throw "Cannot read '$Path': $($_.Exception.Message)"
    }
}

function Test-NwLeaf {
    param($Value, [string]$Type)

    switch ($Type) {
        'bool' { return ($Value -is [bool]) }
        'int' { return ($Value -is [int]) }
        'string' { return ($Value -is [string]) }
    }

    throw "Unknown schema type '$Type'."
}

function Test-NwShape {
    param($Value, $Schema, [string]$Path, [System.Collections.Generic.List[string]]$Errors)

    if ($Schema -is [string]) {
        if (-not (Test-NwLeaf $Value $Schema)) {
            $Errors.Add("$Path must be a $Schema.")
        }

        return
    }

    if (-not ($Value -is [System.Collections.IDictionary])) {
        $Errors.Add("$Path must be a map (@{ ... }).")
        return
    }

    foreach ($key in $Value.Keys) {
        $child = "$Path.$key"

        if ($Schema.ContainsKey('*')) {
            if (-not ([string]$key)) { $Errors.Add("$Path has an empty key."); continue }
            Test-NwShape $Value[$key] $Schema['*'] $child $Errors
        } elseif ($Schema.ContainsKey($key)) {
            Test-NwShape $Value[$key] $Schema[$key] $child $Errors
        } else {
            $Errors.Add("$child is not a known setting.")
        }
    }
}

# Expand the shorthand '<id>' = $true / $false into @{ Enable = ... }.
function ConvertTo-NwNormalLayer {
    param([System.Collections.IDictionary]$Layer)
    $result = @{}
    foreach ($key in $Layer.Keys) { $result[$key] = $Layer[$key] }

    foreach ($section in @('Packages', 'Sources', 'Modules')) {
        if ($result.ContainsKey($section) -and $result[$section] -is [System.Collections.IDictionary]) {
            $map = @{}

            foreach ($id in $result[$section].Keys) {
                $entry = $result[$section][$id]
                if ($entry -is [bool]) { $entry = @{ Enable = $entry } }
                $map[$id] = $entry
            }

            $result[$section] = $map
        }
    }

    return $result
}

function Copy-NwValue {
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $Value.Keys) { $copy[$key] = Copy-NwValue $Value[$key] }
        return $copy
    }

    if ($Value -is [System.Array]) { return , @($Value | ForEach-Object { Copy-NwValue $_ }) }
    return $Value
}

function Merge-NwLayer {
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Overlay)
    $result = Copy-NwValue $Base

    foreach ($key in $Overlay.Keys) {
        if ($result.ContainsKey($key) -and
            $result[$key] -is [System.Collections.IDictionary] -and
            $Overlay[$key] -is [System.Collections.IDictionary]) {
            $result[$key] = Merge-NwLayer $result[$key] $Overlay[$key]
        } else {
            $result[$key] = Copy-NwValue $Overlay[$key]
        }
    }

    return $result
}

function Read-NwLayer {
    param([string]$Path, [string[]]$Exclude = @())
    $data = Import-NwDataFile $Path
    $layer = @{}

    foreach ($key in $data.Keys) {
        if ($Exclude -notcontains $key) { $layer[$key] = $data[$key] }
    }

    $layer = ConvertTo-NwNormalLayer $layer
    $errors = New-Object 'System.Collections.Generic.List[string]'
    Test-NwShape $layer $script:NwSchema 'Settings' $errors

    if ($errors.Count -gt 0) {
        throw ("Invalid settings in '$Path':`n  " + ($errors -join "`n  "))
    }

    return @{ Data = $data; Layer = $layer }
}

function Get-NwRoleChain {
    param([string]$CoreRoot, [string]$Role)
    $chain = @()
    $seen = @{}
    $name = $Role

    while ($name) {
        if ($name -notmatch '^[a-z][a-z0-9-]*$') { throw "Invalid role name '$name'." }
        if ($seen.ContainsKey($name)) { throw "Role '$name' extends itself through '$($chain -join ' -> ')'." }
        $seen[$name] = $true
        $path = Join-Path (Join-Path $CoreRoot 'roles') "$name.psd1"

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $known = @(Get-ChildItem -LiteralPath (Join-Path $CoreRoot 'roles') -Filter '*.psd1' | ForEach-Object { $_.BaseName })
            throw "Unknown role '$name'. Known roles: $($known -join ', ')."
        }

        $read = Read-NwLayer -Path $path -Exclude @('Extends')
        $chain = @(@{ Name = $name; Path = $path; Layer = $read.Layer }) + $chain
        $name = $null

        if ($read.Data.ContainsKey('Extends')) {
            if (-not ($read.Data['Extends'] -is [string])) { throw "Extends in '$path' must be a string." }
            $name = $read.Data['Extends']
        }
    }

    return , $chain
}

# A module name becomes a directory name under each module root. Windows
# strips a trailing dot and cannot make a device name, and the machine
# wrapper rejects 'lock core', which once pinned the core.
function Test-NwModuleName {
    param([string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\z' -or $Name.Contains('..')) { return $false }
    if ($Name.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') { return $false }
    return ($Name -ine 'core')
}

function Assert-NwConfiguration {
    param([System.Collections.IDictionary]$Config)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $configHome = [string]$Config['ConfigHome']

    if (-not $configHome -or [System.IO.Path]::IsPathRooted($configHome) -or
        ($configHome -split '[\\/]') -contains '..') {
        $errors.Add("ConfigHome must be a path inside the home directory, such as '.config'.")
    }

    foreach ($id in $Config['Packages'].Keys) {
        $package = $Config['Packages'][$id]
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { $errors.Add("Packages.$id is not a valid package identifier.") }
        if (-not $package.ContainsKey('Enable')) { $errors.Add("Packages.$id needs Enable.") }

        if ($package.ContainsKey('Source') -and $script:NwPackageSources -notcontains $package['Source']) {
            $errors.Add("Packages.$id.Source must be one of: $($script:NwPackageSources -join ', ').")
        }
    }

    foreach ($name in $Config['Sources'].Keys) {
        $source = $Config['Sources'][$name]
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9]*$') { $errors.Add("Sources.$name must be a name of letters and digits.") }
        if ([string]::Equals($name, 'core', [StringComparison]::OrdinalIgnoreCase)) { $errors.Add("Sources.$name uses the reserved source name 'core'.") }
        if (-not $source.ContainsKey('Enable')) { $errors.Add("Sources.$name needs Enable.") }
        if (-not $source['Enable']) { continue }

        if (-not $source.ContainsKey('Repo') -or $source['Repo'] -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            $errors.Add("Sources.$name.Repo must be a GitHub 'owner/name'.")
        }

        if (-not $source.ContainsKey('Target') -or $source['Target'] -notmatch '^[A-Za-z0-9_.-]+$' -or $source['Target'] -match '^\.+$') {
            $errors.Add("Sources.$name.Target must be one directory name under ConfigHome.")
        }
    }

    foreach ($name in $Config['Modules'].Keys) {
        if (-not (Test-NwModuleName ([string]$name))) {
            $errors.Add("Modules.$name is not a valid module name. Device names, such as 'CON', and 'core' are reserved.")
        }

        if (-not $Config['Modules'][$name].ContainsKey('Enable')) { $errors.Add("Modules.$name needs Enable.") }
    }

    foreach ($name in $Config['Development'].Keys) {
        $match = @($Config['Sources'].Keys | Where-Object { [string]$_ -ieq [string]$name })

        if ($match.Count -ne 1 -or -not $Config['Sources'][$match[0]]['Enable']) {
            $errors.Add("Development.$name names no enabled source.")
        }

        $path = [string]$Config['Development'][$name]

        if (-not $path -or -not [System.IO.Path]::IsPathRooted($path) -or $path -notmatch '^[A-Za-z]:\\') {
            $errors.Add("Development.$name must be an absolute path, such as 'C:\Users\you\codebase\nvim'.")
        }
    }

    if ($errors.Count -gt 0) {
        throw ("Invalid configuration:`n  " + ($errors -join "`n  "))
    }
}

function Resolve-NwConfiguration {
    param([string]$CoreRoot, [string]$MachineRoot)
    $defaults = Read-NwLayer -Path (Join-Path $CoreRoot 'defaults.psd1')
    $machinePath = Join-Path $MachineRoot 'machine.psd1'
    $machine = Read-NwLayer -Path $machinePath

    if (-not $machine.Layer.ContainsKey('SchemaVersion')) {
        throw "'$machinePath' must declare SchemaVersion = $($script:NwSchemaVersion)."
    }

    if ($machine.Layer['SchemaVersion'] -ne $script:NwSchemaVersion) {
        throw "'$machinePath' declares SchemaVersion $($machine.Layer['SchemaVersion']); this core reads $($script:NwSchemaVersion)."
    }

    $role = $defaults.Layer['Role']
    if ($machine.Layer.ContainsKey('Role')) { $role = $machine.Layer['Role'] }

    $config = $defaults.Layer

    foreach ($entry in (Get-NwRoleChain -CoreRoot $CoreRoot -Role $role)) {
        $config = Merge-NwLayer $config $entry.Layer
    }

    $config = Merge-NwLayer $config $machine.Layer
    $config['Role'] = $role
    Assert-NwConfiguration $config
    return $config
}
