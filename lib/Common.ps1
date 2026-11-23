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

function Read-NwJson {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
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

# WinGet asks for the configuration agreement before each configure run,
# also before a test. -Yes gives that consent for runs without a console.
function Get-NwWinGetTestArguments {
    param([string]$Document, [switch]$Yes)
    $arguments = @('configure', 'test', '-f', $Document)
    if ($Yes) { $arguments += '--accept-configuration-agreements' }
    return , $arguments
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
    $uri = Get-NwArchiveUrl -Repo $Repo -Rev $Rev
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
    $response = Invoke-WebRequest -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/commits/$Ref" -Headers $headers
    $content = $response.Content
    # PowerShell 7 returns bytes for a media type that it does not know.
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::ASCII.GetString($content) }
    $rev = ([string]$content).Trim()
    if ($rev -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned no commit for '$Repo' at '$Ref'." }
    return $rev
}
