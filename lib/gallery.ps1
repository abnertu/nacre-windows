# PowerShell Gallery access: the newest stable version of a module, the
# package download and the package contents. NACRE_WINDOWS_GALLERY, a local
# directory of <Id>\<Version>.nupkg files, replaces the Gallery in tests.
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 loads neither assembly by default. The first holds
# ZipArchive, ZipArchiveMode and CompressionLevel.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:NwGalleryUrl = 'https://www.powershellgallery.com/api/v2'

function Get-NwXmlChild {
    param([System.Xml.XmlNode]$Node, [string]$Name)
    foreach ($child in $Node.ChildNodes) { if ($child.LocalName -eq $Name) { return $child } }
    return $null
}

function Get-NwXmlChildText {
    param([System.Xml.XmlNode]$Node, [string]$Name)
    $child = Get-NwXmlChild $Node $Name
    if ($null -eq $child) { return $null }
    return $child.InnerText
}

# Return the version of the one feed entry whose Id equals the name. A
# filter on the Id can still return similar Ids, so this selects exactly.
function Select-NwGalleryEntry {
    param([string]$FeedXml, [string]$Name)
    $feed = New-Object System.Xml.XmlDocument
    $feed.LoadXml($FeedXml)
    # An XmlElement enumerates its children, so collect it in a list.
    $found = New-Object 'System.Collections.Generic.List[System.Xml.XmlNode]'

    foreach ($entry in $feed.SelectNodes("//*[local-name()='entry']")) {
        $properties = Get-NwXmlChild $entry 'properties'
        if ($null -eq $properties) { continue }
        $id = Get-NwXmlChildText $properties 'Id'
        if ([string]::Equals($id, $Name, [StringComparison]::OrdinalIgnoreCase)) { $found.Add($properties) }
    }

    if ($found.Count -ne 1) { throw "The Gallery has $($found.Count) stable latest entries for '$Name', not one." }
    $version = Get-NwXmlChildText $found[0] 'Version'

    if ((ConvertFrom-NwXmlBoolean (Get-NwXmlChildText $found[0] 'IsPrerelease') 'IsPrerelease') -or ([string]$version).Contains('-')) {
        throw "The latest Gallery entry of '$Name' is the prerelease '$version'."
    }

    if (-not (Test-NwVersionText $version)) { throw "The latest Gallery entry of '$Name' has an invalid version: '$version'." }

    return [string]$version
}

function Get-NwLocalGalleryFiles {
    param([string]$Name)
    $directory = Join-Path $env:NACRE_WINDOWS_GALLERY $Name
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "The local gallery has no module '$Name'." }
    $files = @()
    $seen = @{}

    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.nupkg' -File) {
        $text = $file.Name.Substring(0, $file.Name.Length - '.nupkg'.Length)
        if (-not (Test-NwVersionText $text)) { continue }
        $key = (ConvertTo-NwVersion $text).ToString()
        if ($seen.ContainsKey($key)) { throw "The local gallery has two files of version $key for '$Name': $($seen[$key]), $($file.Name)." }
        $seen[$key] = $file.Name
        $files += @{ Text = $text; Version = ConvertTo-NwVersion $text; Path = $file.FullName }
    }

    if ($files.Count -eq 0) { throw "The local gallery has no version of '$Name'." }
    return , $files
}

function Invoke-NwGalleryRequest {
    param([string]$Uri, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    try {
        if ($OutFile) { Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile; return }
        $content = (Invoke-WebRequest -UseBasicParsing -Uri $Uri).Content
        if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
        return [string]$content
    } finally {
        $ProgressPreference = $progress
    }
}

function Get-NwGalleryLatestVersion {
    param([string]$Name)

    if ($env:NACRE_WINDOWS_GALLERY) {
        $files = Get-NwLocalGalleryFiles $Name
        $newest = @($files | Sort-Object { $_.Version } -Descending)[0]
        return $newest.Text
    }

    $filter = [uri]::EscapeDataString("Id eq '$Name' and IsLatestVersion")
    $feed = Invoke-NwGalleryRequest -Uri "$($script:NwGalleryUrl)/Packages()?`$filter=$filter"
    return (Select-NwGalleryEntry -FeedXml $feed -Name $Name)
}

# The Gallery redirects an unknown version to the newest package, so the
# caller compares the nuspec with the request.
function Save-NwGalleryPackage {
    param([string]$Name, [string]$Version, [string]$OutFile)

    if ($env:NACRE_WINDOWS_GALLERY) {
        $wanted = ConvertTo-NwVersion $Version
        $files = Get-NwLocalGalleryFiles $Name
        $match = @($files | Where-Object { $_.Version -eq $wanted })
        if ($match.Count -eq 0) { throw "The local gallery has no version $Version of '$Name'." }
        Copy-Item -LiteralPath $match[0].Path -Destination $OutFile
        return
    }

    Invoke-NwGalleryRequest -Uri "$($script:NwGalleryUrl)/package/$Name/$Version" -OutFile $OutFile
}

function Get-NwZipEntryName {
    param([System.IO.Compression.ZipArchiveEntry]$Entry)
    return [uri]::UnescapeDataString($Entry.FullName).Replace('\', '/')
}

function Read-NwZipEntryText {
    param([System.IO.Compression.ZipArchiveEntry]$Entry)
    $reader = New-Object System.IO.StreamReader($Entry.Open(), $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

# xs:boolean: true, false, 1 or 0. A plain [bool] cast makes 'false' true.
function ConvertFrom-NwXmlBoolean {
    param($Text, [string]$Name)
    if ($null -eq $Text) { return $false }
    $trimmed = ([string]$Text).Trim()
    if ([string]::Equals($trimmed, 'true', [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($trimmed, '1', [StringComparison]::Ordinal)) { return $true }
    if ([string]::Equals($trimmed, 'false', [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($trimmed, '0', [StringComparison]::Ordinal)) { return $false }
    throw "$Name is '$Text', not true or false."
}

function ConvertTo-NwEditions {
    param([System.Collections.IDictionary]$Manifest)
    if (-not $Manifest.ContainsKey('CompatiblePSEditions')) { return , @('Core', 'Desktop') }
    $values = @($Manifest['CompatiblePSEditions'])
    if ($values.Count -eq 0) { throw 'The manifest declares an empty CompatiblePSEditions.' }
    $editions = @{}

    foreach ($value in $values) {
        if (-not ($value -is [string])) { throw "CompatiblePSEditions holds '$value', which is not a string." }
        $known = @('Core', 'Desktop') | Where-Object { [string]::Equals($_, $value.Trim(), [StringComparison]::OrdinalIgnoreCase) }
        if (-not $known) { throw "CompatiblePSEditions holds '$value', not Core or Desktop." }
        $editions[$known] = $true
    }

    return , @(Get-NwSortedKeys $editions)
}

# Dependencies are the union of the plain list and every group. An Id maps
# to the ordinal-sorted unique list of its range texts.
function Get-NwNuspecDependencies {
    param([System.Xml.XmlNode]$Metadata)
    $dependencies = @{}
    $container = Get-NwXmlChild $Metadata 'dependencies'
    if ($null -eq $container) { return $dependencies }

    foreach ($node in $container.SelectNodes(".//*[local-name()='dependency']")) {
        $id = [string]$node.GetAttribute('id')
        if (-not $id) { throw 'The nuspec has a dependency without an id.' }
        if (-not (Test-NwModuleName $id)) { throw "The nuspec dependency '$id' has an invalid id." }
        if (-not $dependencies.ContainsKey($id)) { $dependencies[$id] = @() }

        $dependencies[$id] += [string]$node.GetAttribute('version')
    }

    $result = @{}

    foreach ($id in @($dependencies.Keys)) {
        $unique = @{}
        foreach ($range in $dependencies[$id]) { $unique[$range] = $true }
        [string[]]$ranges = @($unique.Keys)
        [System.Array]::Sort($ranges, [System.StringComparer]::Ordinal)
        [System.Collections.IDictionary[]]$parsed = @($ranges | ForEach-Object { ConvertTo-NwVersionRange $_ })

        if (-not (Test-NwRangeIntersection $parsed)) {
            throw "The package needs '$id' in ranges that share no version: $($ranges -join ', ')."
        }

        $result[$id] = $ranges
    }

    return $result
}

# Read the nuspec and the root module manifest of a nupkg.
# Label names the package in errors; the default is the path.
function Read-NwModulePackage {
    param([string]$Path, [string]$Label = $Path)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('nacre-windows-' + [guid]::NewGuid().ToString('N'))

    try {
        $root = @($zip.Entries | Where-Object { (Get-NwZipEntryName $_) -notmatch '/' })
        $nuspecs = @($root | Where-Object { (Get-NwZipEntryName $_) -like '*.nuspec' })
        if ($nuspecs.Count -ne 1) { throw "'$Label' has $($nuspecs.Count) root .nuspec entries, not one." }
        $nuspec = New-Object System.Xml.XmlDocument
        $nuspec.LoadXml((Read-NwZipEntryText $nuspecs[0]))
        $metadata = $nuspec.SelectSingleNode("/*[local-name()='package']/*[local-name()='metadata']")
        if ($null -eq $metadata) { throw "'$Label' has a nuspec without metadata." }
        $id = Get-NwXmlChildText $metadata 'id'
        $version = Get-NwXmlChildText $metadata 'version'
        if (-not $id -or -not $version) { throw "'$Label' has a nuspec without an id or a version." }
        $license = ConvertFrom-NwXmlBoolean (Get-NwXmlChildText $metadata 'requireLicenseAcceptance') 'requireLicenseAcceptance'
        $dependencies = Get-NwNuspecDependencies $metadata

        $manifests = @($root | Where-Object { [string]::Equals((Get-NwZipEntryName $_), "$id.psd1", [StringComparison]::OrdinalIgnoreCase) })
        if ($manifests.Count -ne 1) { throw "'$Label' has no module manifest '$id.psd1' at its root." }
        New-Item -ItemType Directory -Path $temporary | Out-Null
        $copy = Join-Path $temporary 'manifest.psd1'
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($manifests[0], $copy)

        try {
            $manifest = Import-PowerShellDataFile -LiteralPath $copy
        } catch {
            throw "Cannot read the manifest '$id.psd1': $($_.Exception.Message)"
        }

        if (-not ($manifest['ModuleVersion'] -is [string])) { throw "The manifest '$id.psd1' has no ModuleVersion string." }

        return @{
            Id                       = $id
            Version                  = $version
            ModuleVersion            = $manifest['ModuleVersion']
            Editions                 = ConvertTo-NwEditions $manifest
            RequireLicenseAcceptance = $license
            Dependencies             = $dependencies
        }
    } finally {
        $zip.Dispose()
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}
