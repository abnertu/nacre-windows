#Requires -Version 5.1
# Machine entry point. It runs the nacre-windows core that
# nacre-windows.lock.json pins, after it verifies the archive checksum.
#
#   .\nacre.ps1 plan | switch | upgrade system | doctor | build  [-Yes]
#   .\nacre.ps1 lock [<Name>...] [-Rev <commit> | -Version <version>]
#   .\nacre.ps1 lock core [-Rev <commit>]
#
# A lock name selects a source or a Gallery module.
#
# -OverrideCore <path> runs a local core checkout instead of the pin, to
# preview core changes. Publish them, then adopt them with 'lock core'.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Names = @(),

    [string]$OverrideCore,
    [switch]$Yes,
    [ValidateNotNullOrEmpty()]
    [string]$Rev,
    [ValidateNotNullOrEmpty()]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$machineRoot = $PSScriptRoot
$lockPath = Join-Path $machineRoot 'nacre-windows.lock.json'
$coreRepo = 'abnertu/nacre-windows'

function Get-ArchiveSha256 {
    param([string]$Repo, [string]$Rev, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    try {
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/$Rev.tar.gz" -OutFile $OutFile
    } finally {
        $ProgressPreference = $progress
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLowerInvariant()
}

function Read-CoreLockText {
    $Path = $lockPath
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-Lock {
    if (-not (Test-Path -LiteralPath $lockPath)) { return $null }
    return (ConvertFrom-Json ((Read-CoreLockText)))
}

function Get-CoreLockJson {
    param([System.Collections.IDictionary]$Pin)

    if ($PSVersionTable.PSEdition -eq 'Core' -and (Test-Path -LiteralPath $lockPath)) {
        # PowerShell 7 interprets ISO strings as dates during JSON conversion.
        $reader = [Newtonsoft.Json.JsonTextReader]::new([IO.StringReader]::new((Read-CoreLockText)))

        try {
            $reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
            $document = [Newtonsoft.Json.Linq.JObject]::Load($reader)

            foreach ($property in @($document.Properties())) {
                if ([string]::Equals($property.Name, 'Core', [StringComparison]::OrdinalIgnoreCase)) { $property.Remove() }
            }

            $value = [Newtonsoft.Json.Linq.JObject]::Parse((ConvertTo-Json -InputObject $Pin))
            $document.AddFirst([Newtonsoft.Json.Linq.JProperty]::new('Core', $value))
            return $document.ToString()
        } finally {
            $reader.Dispose()
        }
    }

    $pins = [ordered]@{ Core = $Pin }
    $lock = Read-Lock

    if ($null -ne $lock) {
        foreach ($property in $lock.PSObject.Properties) {
            if ([string]::Equals($property.Name, 'Core', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $pins[$property.Name] = $property.Value
        }
    }

    return (ConvertTo-Json -InputObject $pins -Depth 100)
}

# 'lock core' pins the core itself, so it runs without a core.
if ($Command -eq 'lock' -and $Names.Count -gt 0 -and [string]::Equals($Names[0], 'core', [StringComparison]::OrdinalIgnoreCase)) {
    if ($Names.Count -ne 1) { throw "'lock core' takes no additional names." }
    if ($PSBoundParameters.ContainsKey('Version')) { throw "'lock core' takes -Rev <commit>, not -Version." }
    $ref = 'HEAD'
    if ($Rev) { $ref = $Rev }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ Accept = 'application/vnd.github.sha'; 'User-Agent' = 'nacre-windows' }
    $content = (Invoke-WebRequest -UseBasicParsing -Uri "https://api.github.com/repos/$coreRepo/commits/$ref" -Headers $headers).Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::ASCII.GetString($content) }
    $commit = ([string]$content).Trim()
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned no commit for '$coreRepo' at '$ref'." }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("nacre-windows-$commit-" + [guid]::NewGuid().ToString('N') + '.tar.gz')
    try { $sha = Get-ArchiveSha256 -Repo $coreRepo -Rev $commit -OutFile $file } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }

    # Keep every other key, such as Sources and Modules, with its full value.
    $pin = [ordered]@{ Repo = $coreRepo; Rev = $commit; Sha256 = $sha }
    $hash = [Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($lockPath).ToUpperInvariant())
        $key = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }

    # Keep this mutex name in sync with the core lock command.
    $mutex = [Threading.Mutex]::new($false, "Global\nacre-windows-lock-$key")

    try {
        try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }

        try {
            $text = ((Get-CoreLockJson $pin) -replace "`r`n", "`n") + "`n"
            $temporary = $lockPath + '.tmp-' + [guid]::NewGuid().ToString('N')

            try {
                [IO.File]::WriteAllText($temporary, $text, [Text.UTF8Encoding]::new($false))

                if ([IO.File]::Exists($lockPath)) {
                    [IO.File]::Replace($temporary, $lockPath, [NullString]::Value)
                } else {
                    [IO.File]::Move($temporary, $lockPath)
                }
            } finally {
                [IO.File]::Delete($temporary)
            }
        } finally {
            $mutex.ReleaseMutex()
        }
    } finally {
        $mutex.Dispose()
    }

    Write-Host "Core pinned to $commit."
    exit 0
}

$core = $OverrideCore

if (-not $core) {
    $lock = Read-Lock

    if ($null -eq $lock -or -not $lock.PSObject.Properties['Core']) {
        throw "No core pin in '$lockPath'. Run: .\nacre.ps1 lock core"
    }

    $pin = $lock.Core
    if ($pin.Rev -notmatch '^[0-9a-f]{40}$' -or $pin.Sha256 -notmatch '^[0-9a-f]{64}$') { throw "'$lockPath' has an invalid core pin." }
    $state = $env:NACRE_WINDOWS_STATE
    if (-not $state) { $state = Join-Path $env:LOCALAPPDATA 'nacre-windows' }
    $core = Join-Path (Join-Path $state 'core') $pin.Rev

    if (-not (Test-Path -LiteralPath (Join-Path $core 'nacre-windows.ps1'))) {
        $parent = Split-Path -Parent $core
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $temporary = Join-Path $parent ($pin.Rev + '.tmp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary | Out-Null

        try {
            $archive = Join-Path $temporary 'core.tar.gz'
            $sha = Get-ArchiveSha256 -Repo $pin.Repo -Rev $pin.Rev -OutFile $archive
            if ($sha -ne $pin.Sha256) { throw "Core archive checksum is $sha, not the pinned $($pin.Sha256)." }
            $extract = Join-Path $temporary 'extract'
            New-Item -ItemType Directory -Path $extract | Out-Null
            & tar.exe -xzf $archive -C $extract
            if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE." }
            $top = @(Get-ChildItem -LiteralPath $extract -Directory)
            if ($top.Count -ne 1) { throw 'The core archive has no single top directory.' }
            if (Test-Path -LiteralPath $core) { Remove-Item -LiteralPath $core -Recurse -Force }
            Move-Item -LiteralPath $top[0].FullName -Destination $core
        } finally {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} elseif (-not (Test-Path -LiteralPath (Join-Path $core 'nacre-windows.ps1'))) {
    throw "'$core' is not a nacre-windows checkout."
}

$forward = @{ Machine = $machineRoot }

foreach ($key in $PSBoundParameters.Keys) {
    if ($key -ne 'OverrideCore') { $forward[$key] = $PSBoundParameters[$key] }
}

& (Join-Path $core 'nacre-windows.ps1') @forward
exit $LASTEXITCODE
