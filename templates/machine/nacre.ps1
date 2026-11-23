#Requires -Version 5.1
# Machine entry point. It runs the nacre-windows core that
# nacre-windows.lock.json pins, after it verifies the archive checksum.
#
#   .\nacre.ps1 plan | switch | update | doctor | build  [-Yes]
#   .\nacre.ps1 lock [<Source>...] [-Rev <commit>]
#   .\nacre.ps1 lock core [-Rev <commit>]
#
# -OverrideCore <path> runs a local core checkout instead of the pin, to
# preview core changes. Publish them, then adopt them with 'lock core'.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$machineRoot = $PSScriptRoot
$lockPath = Join-Path $machineRoot 'nacre-windows.lock.json'
$coreRepo = 'abnertu/nacre-windows'

# Take the wrapper's own options out of the arguments for the core.
$override = $null
$rev = $null
$forward = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-OverrideCore' -and $i + 1 -lt $args.Count) {
        $override = $args[$i + 1]
        $i++
        continue
    }
    if ($args[$i] -eq '-Rev' -and $i + 1 -lt $args.Count) { $rev = $args[$i + 1] }
    $forward += $args[$i]
}

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

function Read-Lock {
    if (-not (Test-Path -LiteralPath $lockPath)) { return $null }
    return (ConvertFrom-Json ([System.IO.File]::ReadAllText($lockPath)))
}

# 'lock core' pins the core itself, so it runs without a core.
if ($forward.Count -ge 2 -and $forward[0] -eq 'lock' -and $forward[1] -eq 'core') {
    $ref = 'HEAD'
    if ($rev) { $ref = $rev }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ Accept = 'application/vnd.github.sha'; 'User-Agent' = 'nacre-windows' }
    $content = (Invoke-WebRequest -UseBasicParsing -Uri "https://api.github.com/repos/$coreRepo/commits/$ref" -Headers $headers).Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::ASCII.GetString($content) }
    $commit = ([string]$content).Trim()
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned no commit for '$coreRepo' at '$ref'." }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("nacre-windows-$commit.tar.gz")
    try { $sha = Get-ArchiveSha256 -Repo $coreRepo -Rev $commit -OutFile $file } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }

    $lock = Read-Lock
    $sources = '{}'
    if ($null -ne $lock -and $lock.PSObject.Properties['Sources']) {
        $sources = ($lock.Sources | ConvertTo-Json -Depth 5)
    }
    $text = "{`n  `"Core`": {`n    `"Repo`": `"$coreRepo`",`n    `"Rev`": `"$commit`",`n    `"Sha256`": `"$sha`"`n  },`n  `"Sources`": " + ($sources -replace "`r`n", "`n" -replace "`n", "`n  ") + "`n}`n"
    [System.IO.File]::WriteAllText($lockPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Core pinned to $commit."
    exit 0
}

$core = $override
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

& (Join-Path $core 'nacre-windows.ps1') @forward -Machine $machineRoot
exit $LASTEXITCODE
