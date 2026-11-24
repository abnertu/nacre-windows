# Shared helpers. Keep this file ASCII: Windows PowerShell 5.1 reads a
# BOM-less script as the ANSI code page.
Set-StrictMode -Version Latest

function Get-NwStateRoot {
    if ($env:NACRE_WINDOWS_STATE) { return $env:NACRE_WINDOWS_STATE }
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is required.' }
    return (Join-Path $env:LOCALAPPDATA 'nacre-windows')
}

# An alternate home is a disposable destination: switch never writes
# persistent environment variables for it.
function Test-NwAlternateHome { return [bool]$env:NACRE_WINDOWS_HOME }

function Get-NwHomeRoot {
    if ($env:NACRE_WINDOWS_HOME) { return $env:NACRE_WINDOWS_HOME }
    return $HOME
}

function New-NwDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

# Generated text is UTF-8 without BOM and uses LF line endings.
function Write-NwText {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-NwDirectory $parent }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), $encoding)
}

function Get-NwTextSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Get-NwFileSha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-NwSortedKeys {
    param([System.Collections.IDictionary]$Map)
    [string[]]$keys = @($Map.Keys | ForEach-Object { [string]$_ })
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    return $keys
}

function ConvertTo-NwJsonString {
    param([string]$Text)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')

    foreach ($char in $Text.ToCharArray()) {
        $code = [int]$char

        switch ($char) {
            '"' { [void]$builder.Append('\"'); continue }
            '\' { [void]$builder.Append('\\'); continue }
            default {
                if ($code -lt 0x20) {
                    [void]$builder.Append(('\u{0:x4}' -f $code))
                } else {
                    [void]$builder.Append($char)
                }
            }
        }
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

# Deterministic JSON with ordinal key order. ConvertTo-Json formats
# differently in Windows PowerShell 5.1 and PowerShell 7, so content
# hashes would depend on the host.
function ConvertTo-NwJson {
    param($Value, [int]$Depth = 0)
    $pad = '  ' * $Depth
    $inner = '  ' * ($Depth + 1)
    if ($null -eq $Value) { return 'null' }

    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }

    if ($Value -is [string]) { return (ConvertTo-NwJsonString $Value) }

    if ($Value -is [int] -or $Value -is [long]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [decimal] -or $Value -is [System.Numerics.BigInteger]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [double] -and -not [double]::IsInfinity($Value) -and -not [double]::IsNaN($Value)) {
        return $Value.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @(Get-NwSortedKeys $Value)
        if ($keys.Count -eq 0) { return '{}' }

        $items = foreach ($key in $keys) {
            $inner + (ConvertTo-NwJsonString $key) + ': ' + (ConvertTo-NwJson $Value[$key] ($Depth + 1))
        }

        return "{`n" + ($items -join ",`n") + "`n$pad}"
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $list = @($Value)
        if ($list.Count -eq 0) { return '[]' }
        $items = foreach ($item in $list) { $inner + (ConvertTo-NwJson $item ($Depth + 1)) }
        return "[`n" + ($items -join ",`n") + "`n$pad]"
    }

    throw "Cannot serialize a value of type $($Value.GetType().FullName)."
}

# ConvertFrom-Json in Windows PowerShell 5.1 has no -AsHashtable.
function ConvertTo-NwHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $map = @{}

        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-NwHashtable $property.Value
        }

        return $map
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return , @($Value | ForEach-Object { ConvertTo-NwHashtable $_ })
    }

    return $Value
}

function ConvertFrom-NwJsonToken {
    param($Token)

    switch ($Token.get_Type().ToString()) {
        'Object' {
            $result = @{}

            foreach ($property in $Token.Properties()) {
                $result[$property.Name] = ConvertFrom-NwJsonToken $property.get_Value()
            }

            return $result
        }
        'Array' { return , @($Token.Children() | ForEach-Object { ConvertFrom-NwJsonToken $_ }) }
        default { return $Token.get_Value() }
    }
}

function Read-NwTextForReplace {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-NwJson {
    param([string]$Path)
    $text = Read-NwTextForReplace $Path

    if (-not $text.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) {
        throw "'$Path' is not a JSON object."
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $reader = [Newtonsoft.Json.JsonTextReader]::new([IO.StringReader]::new($text))

        try {
            $reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
            $document = [Newtonsoft.Json.Linq.JObject]::Load($reader)
            if ($reader.Read()) { throw "'$Path' has data after its JSON object." }
            return (ConvertFrom-NwJsonToken $document)
        } finally {
            $reader.Dispose()
        }
    }

    return (ConvertTo-NwHashtable (ConvertFrom-Json $text))
}

function Write-NwJson {
    param([string]$Path, $Value)
    Write-NwText $Path ((ConvertTo-NwJson $Value) + "`n")
}

# Run a native command attached to the console, so interactive prompts and
# colors work. Callers read $script:NwExitCode after -AllowFailure.
function Invoke-NwNative {
    param([string]$Command, [string[]]$Arguments, [switch]$AllowFailure)
    & $Command @Arguments
    $script:NwExitCode = $LASTEXITCODE

    if (-not $AllowFailure -and $script:NwExitCode -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $($script:NwExitCode)."
    }
}

# `winget export` lists the installed packages that WinGet matches to a
# source; a DSC test starts one process per package and is much slower.
# With --include-versions, export leaves out a package whose installed
# version the source no longer offers, so presence uses an export without
# versions, and only pinned packages need the second export.
function Get-NwWinGetExport {
    param([switch]$IncludeVersions)
    $file = Join-Path ([IO.Path]::GetTempPath()) ('nacre-windows-export-' + [guid]::NewGuid().ToString('N') + '.json')

    try {
        $arguments = @('export', '-o', $file, '--accept-source-agreements', '--disable-interactivity')
        if ($IncludeVersions) { $arguments += '--include-versions' }
        & winget @arguments *> $null
        $code = $LASTEXITCODE
        if (-not (Test-Path -LiteralPath $file)) { throw "winget export failed with exit code $code." }
        $export = Read-NwJson $file
        $installed = @{}

        foreach ($source in @($export['Sources'])) {
            $name = [string]$source['SourceDetails']['Name']

            foreach ($package in @($source['Packages'])) {
                $version = ''
                if ($package.ContainsKey('Version')) { $version = [string]$package['Version'] }
                $installed[("$name|" + $package['PackageIdentifier']).ToLowerInvariant()] = $version
            }
        }

        return $installed
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

# The drift lines of the enabled packages, or a Failure message.
function Get-NwPackageDrift {
    param([System.Collections.IDictionary]$Config)
    $declared = @()

    foreach ($id in (Get-NwSortedKeys $Config['Packages'])) {
        $package = $Config['Packages'][$id]
        if (-not $package['Enable']) { continue }
        $source = 'winget'
        if ($package.ContainsKey('Source')) { $source = $package['Source'] }
        $version = ''
        if ($package.ContainsKey('Version') -and $package['Version']) { $version = [string]$package['Version'] }
        $declared += @{ Id = $id; Key = "$source|$id".ToLowerInvariant(); Version = $version }
    }

    try {
        $present = Get-NwWinGetExport
        $versions = @{}
        if (@($declared | Where-Object { $_.Version }).Count -gt 0) { $versions = Get-NwWinGetExport -IncludeVersions }
    } catch {
        return @{ Lines = @(); Failure = $_.Exception.Message }
    }

    $lines = @()

    foreach ($package in $declared) {
        if (-not $present.ContainsKey($package.Key)) {
            $lines += "+ package $($package.Id) (missing or not matched by WinGet; switch installs it)"
        } elseif ($package.Version -and -not $versions.ContainsKey($package.Key)) {
            $lines += "~ package $($package.Id): the installed version is not the declared $($package.Version)"
        } elseif ($package.Version -and $versions[$package.Key] -ne $package.Version) {
            $lines += "~ package $($package.Id) $($versions[$package.Key]), declared $($package.Version)"
        }
    }

    return @{ Lines = $lines; Failure = $null }
}

function Test-NwCommand {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
}

# Add persistent PATH entries that this process does not have yet, such as
# the directory of a package that WinGet just installed. Existing process
# entries keep their order.
function Update-NwProcessPath {
    $current = @($env:Path -split ';' | Where-Object { $_ })
    $known = @{}
    foreach ($entry in $current) { $known[$entry.TrimEnd('\').ToLowerInvariant()] = $true }
    $added = @()

    foreach ($scope in @('Machine', 'User')) {
        $raw = [Environment]::GetEnvironmentVariable('Path', $scope)
        if (-not $raw) { continue }

        foreach ($entry in $raw -split ';') {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim())
            if (-not $expanded) { continue }
            $key = $expanded.TrimEnd('\').ToLowerInvariant()

            if (-not $known.ContainsKey($key)) {
                $known[$key] = $true
                $added += $expanded
            }
        }
    }

    $env:Path = (@($current) + $added) -join ';'
}

# Download a GitHub source archive of one commit.
function Save-NwGitHubArchive {
    param([string]$Repo, [string]$Rev, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # The artifact keeps Get-NwArchiveUrl; only the request honors the test seam.
    $uri = Get-NwArchiveUrl -Repo $Repo -Rev $Rev
    if ($env:NACRE_WINDOWS_GITHUB_ARCHIVE) { $uri = $env:NACRE_WINDOWS_GITHUB_ARCHIVE.TrimEnd('/') + "/$Repo/archive/$Rev.tar.gz" }
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    try {
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $OutFile
    } finally {
        $ProgressPreference = $progress
    }
}

function Get-NwArchiveUrl {
    param([string]$Repo, [string]$Rev)
    return "https://github.com/$Repo/archive/$Rev.tar.gz"
}

function Resolve-NwGitHubRev {
    param([string]$Repo, [string]$Ref = 'HEAD')
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ Accept = 'application/vnd.github.sha'; 'User-Agent' = 'nacre-windows' }
    $api = 'https://api.github.com'
    if ($env:NACRE_WINDOWS_GITHUB_API) { $api = $env:NACRE_WINDOWS_GITHUB_API.TrimEnd('/') }
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$api/repos/$Repo/commits/$Ref" -Headers $headers
    $content = $response.Content
    # PowerShell 7 returns bytes for a media type that it does not know.
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::ASCII.GetString($content) }
    $rev = ([string]$content).Trim()
    if ($rev -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned no commit for '$Repo' at '$Ref'." }
    return $rev
}
