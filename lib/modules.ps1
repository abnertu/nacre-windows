# Evaluate CurrentUser module destinations before any deployment changes.
Set-StrictMode -Version Latest

$script:NwModuleEditionFolders = @{ Core = 'PowerShell'; Desktop = 'WindowsPowerShell' }

$script:NwStagingName = '^[0-9]+(\.[0-9]+){1,3}\.tmp-[0-9a-f]{32}\z'

function Get-NwDocumentsDirectory {
    if (Test-NwAlternateHome) { return (Join-Path (Get-NwHomeRoot) 'Documents') }
    return [Environment]::GetFolderPath('MyDocuments')
}

function Get-NwModulePathItem {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop) } catch [System.Management.Automation.ItemNotFoundException] { return $null }
}

function Test-NwModulePathLink {
    param($Item)
    return ($null -ne $Item -and $Item.LinkType -in 'SymbolicLink', 'Junction')
}

function Test-NwWindowsAbsolutePath {
    param([string]$Path)
    return ($Path -match '^(?:[A-Za-z]:\\|\\\\(?![?.]\\)[^\\]+\\[^\\]+(?:\\|\z))')
}

# Keep each spelling along the path. A link out of a managed directory does
# not let a second owner take a target inside it.
function Resolve-NwPath {
    param([string]$Path, [switch]$PreserveLeaf, [switch]$RequireLinkTargets, [hashtable]$Budget = @{ Links = 32 })
    $full = [IO.Path]::GetFullPath($Path)
    $candidates = @($full)
    $root = [IO.Path]::GetPathRoot($full)
    $parts = @($full.Substring($root.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries))
    $cursor = $root
    $item = Get-NwModulePathItem $root
    $limit = $parts.Count - [int]$PreserveLeaf.IsPresent

    for ($i = 0; $i -lt $limit; $i++) {
        $cursor = [IO.Path]::Combine($cursor, $parts[$i])
        $item = Get-NwModulePathItem $cursor
        if ($null -eq $item) { break }

        if (-not (Test-NwModulePathLink $item)) {
            if ($i -lt ($parts.Count - 1) -and -not $item.PSIsContainer) { throw "'$cursor' is a file. A directory is required." }
            continue
        }

        if ($Budget.Links -le 0) { throw "Too many links while resolving '$Path'." }
        $Budget.Links--
        $target = [string](@($item.Target)[0])
        if (-not $target) { throw "'$cursor' has no link target." }

        if ($target.StartsWith('\') -and -not $target.StartsWith('\\')) {
            $target = [IO.Path]::Combine($root, $target.TrimStart('\'))
        } elseif (-not [IO.Path]::IsPathRooted($target)) {
            $target = [IO.Path]::Combine([IO.Path]::GetDirectoryName($cursor), $target)
        }

        if (-not (Test-NwWindowsAbsolutePath $target)) { throw "'$cursor' links to an incomplete path '$target'." }
        $resolved = Resolve-NwPath -Path $target -RequireLinkTargets:$RequireLinkTargets -Budget $Budget
        $suffix = (($parts | Select-Object -Skip ($i + 1)) -join '\')
        $candidates += @($resolved.Candidates | ForEach-Object { [IO.Path]::Combine($_, $suffix) })

        if ($null -eq $resolved.Item) {
            if ($RequireLinkTargets) { throw "'$cursor' links to missing path '$target'." }
            return @{ Path = [IO.Path]::Combine($resolved.Path, $suffix); Candidates = $candidates; Item = $null }
        }

        if (-not $suffix) {
            return @{ Path = $resolved.Path; Candidates = $candidates; Item = $resolved.Item }
        }

        if (-not $resolved.Item.PSIsContainer) { throw "'$cursor' does not link to a directory." }

        $rest = Resolve-NwPath -Path ([IO.Path]::Combine($resolved.Path, $suffix)) -PreserveLeaf:$PreserveLeaf -RequireLinkTargets:$RequireLinkTargets -Budget $Budget
        return @{ Path = $rest.Path; Candidates = ($candidates + $rest.Candidates); Item = $rest.Item }
    }

    return @{ Path = $full; Candidates = $candidates; Item = $item }
}

function Get-NwModuleRoots {
    param([string]$Documents)
    $Documents = $Documents.Replace('/', '\')

    if (-not (Test-NwWindowsAbsolutePath $Documents)) {
        throw "Documents must be a fully qualified directory for PowerShell modules. Found '$Documents'."
    }

    $resolved = Resolve-NwPath $Documents -RequireLinkTargets

    if ($null -eq $resolved.Item) {
        if (-not (Test-NwAlternateHome)) { throw "Documents directory '$Documents' is unavailable." }
    } elseif (-not $resolved.Item.PSIsContainer) {
        throw "Documents '$Documents' is a file. A directory is required."
    }

    return $resolved
}

function Test-NwModuleManifest {
    param([string]$Path, [string]$Id)
    $item = Get-NwModulePathItem ([IO.Path]::Combine($Path, "$Id.psd1"))
    return ($null -ne $item -and -not $item.PSIsContainer -and -not (Test-NwModulePathLink $item))
}

function Get-NwModuleTargets {
    param($Build)
    $homeRoot = Get-NwHomeRoot

    foreach ($file in $Build.Receipt.Files) {
        $path = Join-Path $homeRoot ($file.Target -replace '/', '\')
        $entry = Resolve-NwPath -Path $path -PreserveLeaf
        $resolved = Resolve-NwPath $path
        @{ Kind = 'Home file'; Target = $file.Target; Paths = ($entry.Candidates + $resolved.Candidates) }
    }

    foreach ($id in (Get-NwSortedKeys $Build.Targets)) {
        $target = $Build.Targets[$id]
        $path = Join-Path $homeRoot ($target -replace '/', '\')
        $resolved = Resolve-NwPath -Path $path -PreserveLeaf:($Build.Links.ContainsKey($id))
        @{ Kind = 'Source target'; Target = $target; Paths = $resolved.Candidates }
    }
}

function Test-NwModulePathOverlap {
    param([string[]]$Targets, [string[]]$ModuleDirectories)

    foreach ($directory in $ModuleDirectories) {
        $modulePath = $directory.Replace('\', '/')

        foreach ($target in $Targets) {
            $targetPath = $target.Replace('\', '/')
            if ((Test-NwPathWithin $targetPath $modulePath) -or (Test-NwPathWithin $modulePath $targetPath)) { return $true }
        }
    }

    return $false
}

# Shared observation for switch, plan and doctor. Only blocking issues stop a
# switch. Missing versions are work for switch, and staging is retry state.
function Get-NwModuleState {
    param($Build, [string]$Documents)
    $state = @{ Documents = $null; Blocking = @(); Warnings = @(); Installs = @(); Staging = @() }
    if ($Build.Modules.Count -eq 0) { return $state }
    if (-not $PSBoundParameters.ContainsKey('Documents')) { $Documents = Get-NwDocumentsDirectory }

    try {
        $resolved = Get-NwModuleRoots $Documents
        $state.Documents = $resolved.Path
        $targets = @(Get-NwModuleTargets $Build)
    } catch {
        $state.Blocking += $_.Exception.Message
        return $state
    }

    foreach ($id in (Get-NwSortedKeys $Build.Modules)) {
        $pin = $Build.Modules[$id]

        foreach ($edition in $pin.Editions) {
            $parts = @($script:NwModuleEditionFolders[$edition], 'Modules', $id, $pin.ModuleVersion)
            $moduleDirectory = [IO.Path]::Combine($state.Documents, $parts[0], $parts[1], $id)
            $versionPath = [IO.Path]::Combine($moduleDirectory, $pin.ModuleVersion)

            try {
                $cursor = $state.Documents
                $item = $null

                foreach ($part in $parts) {
                    $cursor = [IO.Path]::Combine($cursor, $part)
                    $item = Get-NwModulePathItem $cursor
                    if ($null -eq $item) { break }

                    if (-not $item.PSIsContainer -or (Test-NwModulePathLink $item)) {
                        throw "'$cursor' is a file or link. The module path requires a directory."
                    }
                }

                if ($null -ne $item -and -not (Test-NwModuleManifest -Path $versionPath -Id $id)) {
                    throw "'$versionPath' exists without a regular '$id.psd1' manifest."
                }

                $aliases = @($resolved.Candidates | ForEach-Object { [IO.Path]::Combine($_, $parts[0], $parts[1], $id) })

                foreach ($target in $targets) {
                    if (Test-NwModulePathOverlap -Targets $target.Paths -ModuleDirectories $aliases) {
                        $state.Blocking += "$($target.Kind) '$($target.Target)' overlaps the module directory '$moduleDirectory'."
                    }
                }

                if ($null -eq $item) {
                    $state.Installs += @{ Id = $id; Pin = $pin; ModuleDirectory = $moduleDirectory; VersionPath = $versionPath }
                }

                if (-not [IO.Directory]::Exists($moduleDirectory)) { continue }

                foreach ($child in Get-ChildItem -LiteralPath $moduleDirectory -Directory -Force) {
                    if ($child.Name -cmatch $script:NwStagingName) {
                        $state.Staging += $child
                        $state.Warnings += "Stale module staging directory '$($child.FullName)'. Switch removes it."
                    } elseif ((Test-NwVersionText $child.Name) -and [version]$child.Name -gt [version]$pin.ModuleVersion -and
                        (Test-NwModuleManifest -Path $child.FullName -Id $id)) {
                        $state.Warnings += "PowerShell module '$id' has a higher version '$($child.Name)' in '$moduleDirectory'. It loads before '$($pin.ModuleVersion)'."
                    }
                }
            } catch {
                $state.Blocking += "PowerShell module '$id' for edition $($edition): $($_.Exception.Message)"
            }
        }
    }

    return $state
}

function Remove-NwStagingEntry {
    param([IO.FileSystemInfo]$Item)

    if ($Item.Attributes -band [IO.FileAttributes]::Directory) {
        # A reparse directory is a leaf for cleanup, including when it is
        # inside a real staging directory.
        if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            foreach ($child in $Item.EnumerateFileSystemInfos()) { Remove-NwStagingEntry $child }
        }

        [IO.Directory]::Delete($Item.FullName)
    } else {
        [IO.File]::Delete($Item.FullName)
    }
}

function Expand-NwModulePackage {
    param([IO.Compression.ZipArchive]$Zip, [string]$Staging)
    $prefix = [IO.Path]::GetFullPath($Staging).TrimEnd('\') + '\'
    $invalidCharacters = [IO.Path]::GetInvalidFileNameChars()

    foreach ($entry in $Zip.Entries) {
        $name = Get-NwZipEntryName $entry
        $directory = $name.EndsWith('/')
        $path = $name
        if ($directory) { $path = $path.Substring(0, $path.Length - 1) }

        foreach ($part in $path.Split('/')) {
            if (-not $part -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
                $part.IndexOfAny($invalidCharacters) -ge 0 -or
                $part.Split('.')[0].TrimEnd(' ') -imatch '^(?:CON|CONIN\$|CONOUT\$|PRN|AUX|NUL|COM[0-9\u00B9\u00B2\u00B3]|LPT[0-9\u00B9\u00B2\u00B3])\z') {
                throw "Invalid module package entry '$name'."
            }
        }

        $destination = [IO.Path]::GetFullPath([IO.Path]::Combine($prefix, $path.Replace('/', '\')))

        if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Module package entry '$name' is outside its staging directory."
        }

        if ($directory -or $name -match '^(?:_rels|package)/' -or [string]::Equals($name, '[Content_Types].xml', [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($name, '.signature.p7s', [StringComparison]::OrdinalIgnoreCase) -or
            ($name -notmatch '/' -and $name -like '*.nuspec')) {
            continue
        }

        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination)
    }
}

function Install-NwModuleVersion {
    param($Install, [IO.Compression.ZipArchive]$Zip)
    $staging = $Install.VersionPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [void](Get-NwRelativePath -Root $Install.ModuleDirectory -Path $staging)
    [void][IO.Directory]::CreateDirectory($staging)

    try {
        Expand-NwModulePackage -Zip $Zip -Staging $staging

        if (-not (Test-NwModuleManifest -Path $staging -Id $Install.Id)) {
            throw "The staged module '$($Install.Id)' has no manifest."
        }

        try {
            [IO.Directory]::Move($staging, $Install.VersionPath)
        } catch {
            $published = Get-NwModulePathItem $Install.VersionPath

            if ($null -eq $published -or -not $published.PSIsContainer -or (Test-NwModulePathLink $published) -or
                -not (Test-NwModuleManifest -Path $Install.VersionPath -Id $Install.Id)) {
                throw
            }
        }

        Write-Host "Installed PowerShell module '$($Install.Id)' to '$($Install.VersionPath)'."
    } finally {
        $remaining = Get-NwModulePathItem $staging
        if ($null -ne $remaining) { Remove-NwStagingEntry $remaining }
    }
}

function Install-NwModules {
    param($State)
    foreach ($directory in $State.Staging) { Remove-NwStagingEntry $directory }

    foreach ($group in ($State.Installs | Group-Object { $_.Id })) {
        $id = $group.Group[0].Id
        $pin = $group.Group[0].Pin
        $archive = Join-Path ([IO.Path]::GetTempPath()) ('nacre-module-' + [guid]::NewGuid().ToString('N') + '.nupkg')

        try {
            Save-NwGalleryPackage -Name $id -Version $pin.Version -OutFile $archive
            if ((Get-NwFileSha256 $archive) -cne $pin.Sha256) { throw "SHA-256 mismatch for PowerShell module '$id' version '$($pin.Version)'." }

            $package = Read-NwModulePackage -Path $archive -Label $id

            if (-not [string]::Equals($package.Id, $id, [StringComparison]::OrdinalIgnoreCase) -or (ConvertTo-NwVersion $package.Version) -ne (ConvertTo-NwVersion $pin.Version)) {
                throw "Module package '$($package.Id)' version '$($package.Version)' differs from pin '$id' version '$($pin.Version)'."
            }

            if (-not [string]::Equals($package.ModuleVersion, $pin.ModuleVersion, [StringComparison]::Ordinal)) {
                throw "ModuleVersion '$($package.ModuleVersion)' of '$id' differs from pin '$($pin.ModuleVersion)'."
            }

            $zip = [IO.Compression.ZipFile]::OpenRead($archive)

            try {
                foreach ($install in $group.Group) { Install-NwModuleVersion -Install $install -Zip $zip }
            } finally {
                $zip.Dispose()
            }
        } finally {
            [IO.File]::Delete($archive)
        }
    }
}
