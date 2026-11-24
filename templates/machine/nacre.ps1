#Requires -Version 5.1
# Machine entry point. It runs the nacre-windows core that
# nacre-windows.lock.json pins, after it verifies the cached core.
#
#   .\nacre.ps1 plan | switch | upgrade system | doctor | build  [-Yes]
#   .\nacre.ps1 lock [<Name>...] [-Rev <commit> | -Version <version>]
#   .\nacre.ps1 upgrade self [-Rev <commit>] [-Ref <branch> | -Release] [-Yes]
#
# A lock name selects a source or a Gallery module.
#
# upgrade self pins the newest core on the lock's channel (Core.Ref: a branch,
# or absent for the newest release), then plans, asks and switches under it.
#
# -OverrideCore <path> runs a local core checkout instead of the pin, to
# preview core changes. Publish them, then adopt them with 'upgrade self'.

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
    [string]$Version,
    [ValidateNotNullOrEmpty()]
    [string]$Ref,
    [switch]$Release,
    [ValidateNotNullOrEmpty()]
    [string]$MachineRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$upgradeSelf = $Command -eq 'upgrade' -and $Names.Count -gt 0 -and $Names[0] -eq 'self'

if (-not $upgradeSelf) {
    foreach ($name in @('Ref', 'Release', 'MachineRoot')) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "Usage: -$name applies only to 'upgrade self'." }
    }
}

if ($Command -eq 'lock' -and $Names.Count -gt 0 -and [string]::Equals($Names[0], 'core', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Usage: 'lock core' was removed. Run: .\nacre.ps1 upgrade self"
}

# PowerShell names are case-insensitive, so this must not be named like -MachineRoot.
$machineDirectory = $PSScriptRoot
if ($MachineRoot) { $machineDirectory = (Resolve-Path -LiteralPath $MachineRoot).Path }
$lockPath = Join-Path $machineDirectory 'nacre-windows.lock.json'
$defaultRepo = 'abnertu/nacre-windows'
# Tests point these at a local server.
$apiBase = 'https://api.github.com'
if ($env:NACRE_WINDOWS_GITHUB_API) { $apiBase = $env:NACRE_WINDOWS_GITHUB_API.TrimEnd('/') }
$archiveBase = 'https://github.com'
if ($env:NACRE_WINDOWS_GITHUB_ARCHIVE) { $archiveBase = $env:NACRE_WINDOWS_GITHUB_ARCHIVE.TrimEnd('/') }
$state = $env:NACRE_WINDOWS_STATE
if (-not $state) { $state = Join-Path $env:LOCALAPPDATA 'nacre-windows' }
$cacheRoot = Join-Path $state 'core'

function Invoke-GitHubJson {
    param([string]$Path, [switch]$AllowMissing)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'nacre-windows' }

    try {
        $content = (Invoke-WebRequest -UseBasicParsing -Uri "$apiBase/$Path" -Headers $headers).Content
    } catch {
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($AllowMissing -and $code -eq 404) { return $null }
        throw
    }

    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return (ConvertFrom-Json ([string]$content))
}

function ConvertTo-UrlPath {
    param([string]$Value)
    return ((@($Value -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}

function Save-CoreArchive {
    param([string]$Repo, [string]$Commit, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$archiveBase/$Repo/archive/$Commit.tar.gz" -OutFile $OutFile
    } finally {
        $ProgressPreference = $progress
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLowerInvariant()
}

# SHA-256 of "<path>\0<file sha256>\n" lines, sorted by ordinal path.
function Get-TreeHash {
    param([string]$Directory)
    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')

    $lines = @(Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object {
            $path = $_.FullName.Substring($full.Length + 1).Replace('\', '/')
            $path + [char]0 + (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        })

    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $text = ($lines | ForEach-Object { $_ + "`n" }) -join ''
    $hash = [Security.Cryptography.SHA256]::Create()

    try {
        return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }
}

# Extract an archive into the cache and record its archive and tree hashes.
function Install-CachedCore {
    param([string]$Archive, [string]$Commit, [string]$Sha256)
    $core = Join-Path $cacheRoot $Commit
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $temporary = Join-Path $cacheRoot ($Commit + '.tmp-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null

    try {
        & tar.exe -xzf $Archive -C $temporary
        if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE." }
        $top = @(Get-ChildItem -LiteralPath $temporary -Directory)
        if ($top.Count -ne 1) { throw 'The core archive has no single top directory.' }
        if (Test-Path -LiteralPath $core) { Remove-Item -LiteralPath $core -Recurse -Force }
        Move-Item -LiteralPath $top[0].FullName -Destination $core
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }

    $record = [ordered]@{ Sha256 = $Sha256; Tree = (Get-TreeHash $core) }
    [IO.File]::WriteAllText($core + '.json', (ConvertTo-Json -InputObject $record), [Text.UTF8Encoding]::new($false))
    return $core
}

# The cached core of a pin, verified against the pin; downloaded when absent.
function Get-CachedCore {
    param($Pin)
    $core = Join-Path $cacheRoot $Pin.Rev
    $recordPath = $core + '.json'

    if ((Test-Path -LiteralPath $recordPath) -and (Test-Path -LiteralPath (Join-Path $core 'nacre-windows.ps1'))) {
        $record = ConvertFrom-Json ([IO.File]::ReadAllText($recordPath))
        if ($record.Sha256 -ne $Pin.Sha256) { throw "Cached core $core has archive hash $($record.Sha256), not the pinned $($Pin.Sha256). Delete '$core' and '$recordPath', then run again." }
        $tree = Get-TreeHash $core
        if ($tree -ne $record.Tree) { throw "Cached core $core changed: tree hash $tree, recorded $($record.Tree). Delete '$core' and '$recordPath', then run again." }
        return $core
    }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('nacre-windows-' + [guid]::NewGuid().ToString('N') + '.tar.gz')

    try {
        $sha = Save-CoreArchive -Repo $Pin.Repo -Commit $Pin.Rev -OutFile $temporary
        if ($sha -ne $Pin.Sha256) { throw "Core archive checksum is $sha, not the pinned $($Pin.Sha256)." }
        return (Install-CachedCore -Archive $temporary -Commit $Pin.Rev -Sha256 $sha)
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Read-CoreLockText {
    $stream = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-Lock {
    if (-not (Test-Path -LiteralPath $lockPath)) { return $null }
    return (ConvertFrom-Json ((Read-CoreLockText)))
}

function Get-CorePin {
    $lock = Read-Lock
    if ($null -eq $lock -or -not $lock.PSObject.Properties['Core']) { return $null }
    return $lock.Core
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

function Write-CorePin {
    param([System.Collections.IDictionary]$Pin)
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
            $text = ((Get-CoreLockJson $Pin) -replace "`r`n", "`n") + "`n"
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
}

function Test-BranchName {
    param([string]$Name)

    foreach ($segment in @($Name -split '/')) {
        if ($segment -notmatch '^[A-Za-z0-9._-]+$' -or $segment -eq '.' -or $segment -eq '..' -or $segment.EndsWith('.lock')) { return $false }
    }

    return $true
}

# A console that can answer: no -NonInteractive (any prefix from -noni) and
# no redirected input. Tests force one with NACRE_WINDOWS_INTERACTIVE=1.
function Test-Interactive {
    if (-not [Environment]::UserInteractive) { return $false }

    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        if ($argument -match '^-noni(n(t(e(r(a(c(t(i(v(e)?)?)?)?)?)?)?)?)?)?$') { return $false }
    }

    # Tests set NACRE_WINDOWS_INTERACTIVE=1 to read answers from redirected input.
    return ($env:NACRE_WINDOWS_INTERACTIVE -eq '1' -or -not [Console]::IsInputRedirected)
}

function Format-Revision {
    param([string]$Commit, [string]$Label)
    if (-not $Commit) { return 'no pin' }
    $short = $Commit.Substring(0, [Math]::Min(12, $Commit.Length))
    if ($Label) { return "$short ($Label)" }
    return $short
}

function Invoke-Core {
    param([string]$Core, [string]$CoreCommand, [switch]$WithYes)
    $arguments = @{ Command = $CoreCommand; Machine = $machineDirectory }
    if ($CoreCommand -eq 'upgrade') { $arguments['Names'] = @('system') }
    if ($WithYes) { $arguments['Yes'] = $true }
    # Out-Host keeps the core's output out of this function's return value.
    & (Join-Path $Core 'nacre-windows.ps1') @arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-UpgradeSelf {
    if ($Names.Count -ne 1) { throw "Usage: upgrade self takes no names: $($Names[1..($Names.Count - 1)] -join ' ')." }
    if ($OverrideCore) { throw 'Usage: upgrade self pins a published core; -OverrideCore only previews a local core.' }
    if ($Version) { throw 'Usage: upgrade self takes -Rev, -Ref or -Release, not -Version.' }
    if ($Ref -and $Release) { throw 'Usage: give -Ref <branch> or -Release, not both.' }
    if ($Rev -and $Rev -notmatch '^[0-9a-f]{40}$') { throw "-Rev must be a full 40-character commit, not '$Rev'." }
    if ($Ref -and -not (Test-BranchName $Ref)) { throw "-Ref '$Ref' is not a valid branch name." }

    $current = Get-CorePin
    $repo = $defaultRepo
    $oldRef = ''

    if ($null -ne $current) {
        if ($current.PSObject.Properties['Repo'] -and $current.Repo) { $repo = [string]$current.Repo }
        if ($current.PSObject.Properties['Ref'] -and $current.Ref) { $oldRef = [string]$current.Ref }
    }

    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "The lock's Core.Repo '$repo' is not an owner/name repository." }
    if ($oldRef -and -not (Test-BranchName $oldRef)) { throw "The lock's Core.Ref '$oldRef' is not a valid branch name." }

    $newRef = $oldRef
    if ($Ref) { $newRef = $Ref }
    if ($Release) { $newRef = '' }
    $explicit = $Rev -or $Ref -or $Release

    if ($Rev) {
        $commit = $Rev
        $label = $newRef
    } elseif ($newRef) {
        $branch = Invoke-GitHubJson "repos/$repo/branches/$(ConvertTo-UrlPath $newRef)" -AllowMissing
        if ($null -eq $branch) { throw "Branch '$newRef' does not exist in $repo." }
        $commit = [string]$branch.commit.sha
        $label = $newRef
    } else {
        $latest = Invoke-GitHubJson "repos/$repo/releases/latest" -AllowMissing
        if ($null -eq $latest) { throw "$repo has no release yet. Run: .\nacre.ps1 upgrade self -Ref <branch>" }
        $tag = [string]$latest.tag_name
        $commit = [string](Invoke-GitHubJson "repos/$repo/commits/$(ConvertTo-UrlPath $tag)").sha
        $label = $tag

        if (-not $explicit -and $null -ne $current -and $current.Rev -ne $commit) {
            $comparison = Invoke-GitHubJson "repos/$repo/compare/$(ConvertTo-UrlPath $tag)...$($current.Rev)" -AllowMissing
            if ($null -eq $comparison) { throw "The pinned commit $($current.Rev) was not found in $repo. Run: .\nacre.ps1 upgrade self -Release" }

            if (@('ahead', 'diverged') -contains [string]$comparison.status) {
                throw "The pinned commit $($current.Rev) is not behind the newest release $tag at $commit (GitHub: $($comparison.status)). Run '.\nacre.ps1 upgrade self -Ref main' to follow main, or '.\nacre.ps1 upgrade self -Release' to pin $tag."
            }
        }
    }

    if ($commit -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned no commit for $repo at '$label'." }

    if ($null -ne $current -and $current.Rev -eq $commit -and $oldRef -eq $newRef) {
        $core = Get-CachedCore $current
    } else {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('nacre-windows-' + [guid]::NewGuid().ToString('N') + '.tar.gz')

        try {
            $sha = Save-CoreArchive -Repo $repo -Commit $commit -OutFile $temporary
            $core = Install-CachedCore -Archive $temporary -Commit $commit -Sha256 $sha
        } finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }

        $pin = [ordered]@{ Repo = $repo }
        if ($newRef) { $pin['Ref'] = $newRef }
        $pin['Rev'] = $commit
        $pin['Sha256'] = $sha
        Write-CorePin $pin
    }

    $oldCommit = ''
    if ($null -ne $current) { $oldCommit = [string]$current.Rev }
    Write-Host "nacre-windows: $(Format-Revision $oldCommit $oldRef) -> $(Format-Revision $commit $label)"

    # -Yes for plan accepts only the WinGet agreement of its read-only test.
    $code = Invoke-Core -Core $core -CoreCommand 'plan' -WithYes
    if ($code -ne 0) { return $code }

    $apply = [bool]$Yes

    if (-not $apply -and (Test-Interactive)) {
        Write-Host -NoNewline 'Apply this plan with switch? [y/N] '
        $answer = [Console]::ReadLine()
        $apply = $null -ne $answer -and $answer -match '^[Yy]'
    }

    if (-not $apply) {
        Write-Host 'Not applied. Run: nacre switch'
        return 0
    }

    return (Invoke-Core -Core $core -CoreCommand 'switch' -WithYes)
}

if ($upgradeSelf) { exit (Invoke-UpgradeSelf) }

$core = $OverrideCore

if (-not $core) {
    $pin = Get-CorePin
    if ($null -eq $pin) { throw "No core pin in '$lockPath'. Run: .\nacre.ps1 upgrade self" }
    if ($pin.Rev -notmatch '^[0-9a-f]{40}$' -or $pin.Sha256 -notmatch '^[0-9a-f]{64}$') { throw "'$lockPath' has an invalid core pin." }
    $core = Get-CachedCore $pin
} elseif (-not (Test-Path -LiteralPath (Join-Path $core 'nacre-windows.ps1'))) {
    throw "'$core' is not a nacre-windows checkout."
}

$forward = @{ Machine = $machineDirectory }

foreach ($key in $PSBoundParameters.Keys) {
    if ($key -ne 'OverrideCore') { $forward[$key] = $PSBoundParameters[$key] }
}

& (Join-Path $core 'nacre-windows.ps1') @forward
exit $LASTEXITCODE
