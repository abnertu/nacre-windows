# Test helpers for run-tests.ps1.
Set-StrictMode -Version Latest

function Test {
    param([string]$Name, [scriptblock]$Body)
    $full = "$($script:CurrentFile): $Name"
    if ($full -notlike $Filter) { return }

    try {
        & $Body
        $script:Passed++
        Write-Host "  ok    $full"
    } catch {
        $script:Failed += $full
        Write-Host "  FAIL  $full"
        Write-Host ("        " + ($_.Exception.Message -replace "`n", "`n        "))
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message = '')
    if ($Text -notmatch $Pattern) { throw "Expected /$Pattern/ $Message. Output:`n$Text" }
}

# An error message, which PowerShell wraps at the console width: 5.1 breaks
# native error records, and 7 starts each wrapped line of an error view with
# '|'. Compare without whitespace; keep '.*' out of the pattern.
function Assert-ErrorMatch {
    param([string]$Text, [string]$Pattern)
    $flat = ($Text -replace '(?m)^\s*\|', '') -replace '\s+', ''
    if ($flat -notmatch ($Pattern -replace ' ', '')) { throw "Expected the error /$Pattern/. Output:`n$Text" }
}

function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Message = '')
    if ($Text -match $Pattern) { throw "Did not expect /$Pattern/ $Message. Output:`n$Text" }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $message = $null
    try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
    if ($null -eq $message) { throw "Expected an error /$Pattern/." }
    Assert-Match $message $Pattern 'in the error'
}

function New-TestRoot {
    $path = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $path | Out-Null

    foreach ($name in @('machine', 'state', 'home', 'bin')) {
        New-Item -ItemType Directory -Path (Join-Path $path $name) | Out-Null
    }

    # Fake native commands log their arguments. An exit code comes from
    # NW_FAKE_<COMMAND>_EXIT. 'winget export' writes NW_FAKE_WINGET_EXPORT, or
    # an export without packages.
    $winget = @(
        '@echo off'
        'if not "%1"=="--version" goto run'
        'if defined NW_FAKE_WINGET_VERSION (echo %NW_FAKE_WINGET_VERSION%) else (echo v1.12.0)'
        'exit /b 0'
        ':run'
        'echo winget %*>>"%NW_FAKE_LOG%"'
        'if not "%1"=="export" goto configure'
        'set "NW_EXPORT=%NW_FAKE_WINGET_EXPORT%"'
        'echo %* | findstr /c:"--include-versions" >nul && if defined NW_FAKE_WINGET_EXPORT_VERSIONS set "NW_EXPORT=%NW_FAKE_WINGET_EXPORT_VERSIONS%"'
        'if defined NW_EXPORT (copy /y "%NW_EXPORT%" "%3" >nul) else (echo {"Sources":[]}>"%3")'
        'exit /b 0'
        ':configure'
        'if defined NW_FAKE_WINGET_EXIT exit /b %NW_FAKE_WINGET_EXIT%'
        'exit /b 0'
    )

    $chezmoi = @(
        '@echo off'
        'echo chezmoi %*>>"%NW_FAKE_LOG%"'
        'if defined NW_FAKE_CHEZMOI_EXIT exit /b %NW_FAKE_CHEZMOI_EXIT%'
        'exit /b 0'
    )

    [System.IO.File]::WriteAllText((Join-Path $path 'bin\winget.cmd'), ($winget -join "`r`n") + "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $path 'bin\chezmoi.cmd'), ($chezmoi -join "`r`n") + "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $path 'log.txt'), '')
    return $path
}

function Set-TestFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"))
}

function New-TestMachine {
    param([string]$Settings = '', [hashtable]$HomeFiles = @{}, [string]$Lock, [switch]$WithoutRoleModules)
    $root = New-TestRoot
    if ($WithoutRoleModules) { $Settings += "`n    Modules = @{ PSReadLine = `$false }" }
    Set-TestFile (Join-Path $root 'machine\machine.psd1') "@{`n    SchemaVersion = 1`n$Settings`n}`n"

    foreach ($relative in $HomeFiles.Keys) {
        Set-TestFile (Join-Path (Join-Path $root 'machine\files') $relative) $HomeFiles[$relative]
    }

    if ($Lock) { Set-TestFile (Join-Path $root 'machine\nacre-windows.lock.json') $Lock }
    return $root
}

# Run a script in a child process of this host with the test environment.
# Returns @{ ExitCode; Output; Log }.
function Invoke-TestScript {
    param([string]$Root, [string]$Script, [string[]]$Arguments = @(), [hashtable]$Environment = @{}, [string[]]$InputText, [switch]$Interactive)

    $variables = @{
        NACRE_WINDOWS_STATE = (Join-Path $Root 'state')
        NACRE_WINDOWS_HOME  = (Join-Path $Root 'home')
        NW_FAKE_LOG         = (Join-Path $Root 'log.txt')
        Path                = (Join-Path $Root 'bin') + ';' + $env:Path
    }

    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    $saved = @{}

    foreach ($key in $variables.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $variables[$key], 'Process')
    }

    $hostArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (-not $Interactive) { $hostArguments += '-NonInteractive' }

    # Windows PowerShell 5.1 turns redirected stderr into terminating errors
    # under Stop; the child's own exit code reports failure instead.
    $preference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        if ($PSBoundParameters.ContainsKey('InputText')) {
            # Piped lines become the child's stdin; an empty array is end of input.
            $output = $InputText | & $script:Shell @hostArguments -File $Script @Arguments 2>&1 | Out-String
        } else {
            $output = & $script:Shell @hostArguments -File $Script @Arguments 2>&1 | Out-String
        }

        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $preference
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }

    return @{
        ExitCode = $code
        Output   = $output
        Log      = [System.IO.File]::ReadAllText((Join-Path $Root 'log.txt'))
    }
}

function Invoke-Nw {
    param([string]$Root, [string[]]$Arguments, [hashtable]$Environment = @{})
    $script = Join-Path $script:CoreRoot 'nacre-windows.ps1'
    return (Invoke-TestScript -Root $Root -Script $script -Arguments ($Arguments + @('-Machine', (Join-Path $Root 'machine'))) -Environment $Environment)
}

function Assert-Success {
    param($Result)
    if ($Result.ExitCode -ne 0) { throw "Exit code $($Result.ExitCode). Output:`n$($Result.Output)" }
}

function Assert-Failure {
    param($Result, [string]$Pattern)
    if ($Result.ExitCode -eq 0) { throw "Expected a failure. Output:`n$($Result.Output)" }
    if ($Result.Output -notmatch $Pattern) { Assert-ErrorMatch $Result.Output $Pattern }
}

# Build and return the artifact directory.
function Invoke-TestBuild {
    param([string]$Root)
    $result = Invoke-Nw -Root $Root -Arguments @('build')
    Assert-Success $result
    $path = @($result.Output -split "`r?`n" | Where-Object { $_.Trim() })[-1].Trim()
    Assert-True (Test-Path -LiteralPath (Join-Path $path 'receipt.json')) "No artifact at '$path'."
    return $path
}

function Read-TestText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

# Write a zip file of entry name -> text, as a nupkg is.
function New-TestZip {
    param([string]$Path, [System.Collections.IDictionary]$Entries)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)

    try {
        foreach ($name in $Entries.Keys) {
            $writer = New-Object System.IO.StreamWriter($zip.CreateEntry($name).Open())
            try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
        }
    } finally {
        $zip.Dispose()
    }
}

# Add a fake module package to a local gallery at <Gallery>\<Id>\<File>.nupkg.
# Each part of the nuspec and the manifest can be replaced.
function New-TestModulePackage {
    param(
        [string]$Gallery,
        [string]$Id,
        [string]$Version,
        [string]$File = $Version,
        [string]$NuspecId = $Id,
        [string]$NuspecVersion = $Version,
        [string]$ModuleVersion = $Version,
        [string]$ManifestLines = '',
        [string]$Dependencies = '',
        [string]$License = '',
        [string]$Manifest,
        [System.Collections.IDictionary]$Extra = @{},
        [switch]$NoManifest
    )

    $metadata = "    <id>$NuspecId</id>`n    <version>$NuspecVersion</version>`n    <authors>test</authors>`n"
    if ($License) { $metadata += "    <requireLicenseAcceptance>$License</requireLicenseAcceptance>`n" }
    if ($Dependencies) { $metadata += "    <dependencies>$Dependencies</dependencies>`n" }

    $entries = [ordered]@{
        '_rels/.rels'                                        = '<Relationships />'
        "$NuspecId.nuspec"                                   = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<package xmlns=`"http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd`">`n  <metadata>`n$metadata  </metadata>`n</package>`n"
        "$NuspecId.psm1"                                     = "function Get-$($NuspecId -replace '[^A-Za-z0-9]', '') { '$ModuleVersion' }`n"
        '[Content_Types].xml'                                = '<Types />'
        'package/services/metadata/core-properties/x.psmdcp' = '<coreProperties />'
    }

    if (-not $NoManifest) {
        if (-not $PSBoundParameters.ContainsKey('Manifest')) {
            $Manifest = "@{`n    ModuleVersion = '$ModuleVersion'`n    RootModule = '$NuspecId.psm1'`n$ManifestLines`n}`n"
        }

        $entries["$NuspecId.psd1"] = $Manifest
    }

    foreach ($name in $Extra.Keys) { $entries[$name] = $Extra[$name] }
    $path = Join-Path (Join-Path $Gallery $Id) "$File.nupkg"
    New-TestZip -Path $path -Entries $entries
    return $path
}

# A local GitHub stand-in on http://localhost:<port>/ in its own runspace.
# Routes map a request path to a JSON string or to archive bytes; other paths
# answer 404. Every request path lands in Log.
function Start-TestWeb {
    param([hashtable]$Routes)
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    $log = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $shared = [hashtable]::Synchronized($Routes)
    $runner = [PowerShell]::Create()

    [void]$runner.AddScript({
            param($Listener, $Routes, $Log)

            while ($Listener.IsListening) {
                try { $context = $Listener.GetContext() } catch { break }
                $path = $context.Request.Url.AbsolutePath
                $Log.Enqueue($path)
                $body = $Routes[$path]
                $response = $context.Response

                if ($null -eq $body) {
                    $response.StatusCode = 404
                    $bytes = [Text.Encoding]::UTF8.GetBytes('{"message":"Not Found"}')
                } elseif ($body -is [byte[]]) {
                    $bytes = $body
                } else {
                    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$body)
                }

                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.Close()
            }
        }).AddArgument($listener).AddArgument($shared).AddArgument($log)

    $handle = $runner.BeginInvoke()
    $url = "http://localhost:$port"

    return @{
        Url         = $url
        Routes      = $shared
        Log         = $log
        Listener    = $listener
        Runner      = $runner
        Handle      = $handle
        Environment = @{ NACRE_WINDOWS_GITHUB_API = $url; NACRE_WINDOWS_GITHUB_ARCHIVE = $url }
    }
}

function Stop-TestWeb {
    param($Web)
    $Web.Listener.Stop()
    $Web.Listener.Close()
    $Web.Runner.Dispose()
}

# A tar.gz of the working-tree core under one top directory, and its hash.
function New-TestCoreArchive {
    param([string]$Extra = '')
    $root = Join-Path $script:TempRoot ('core-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $top = Join-Path $root 'nacre-windows-fixture'
    New-Item -ItemType Directory -Force -Path $top | Out-Null

    foreach ($item in Get-ChildItem -LiteralPath $script:CoreRoot -Force) {
        if (@('.git', '.blueprints') -contains $item.Name) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $top -Recurse -Force
    }

    if ($Extra) { Set-TestFile (Join-Path $top 'extra.txt') $Extra }
    $archive = Join-Path $root 'core.tar.gz'
    & tar.exe -czf $archive -C $root 'nacre-windows-fixture'
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE." }

    return @{
        Bytes  = [IO.File]::ReadAllBytes($archive)
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    }
}

# A winget export file in which every declared package is installed.
function New-TestInstalledExport {
    param([string]$Root)
    . (Join-Path $script:CoreRoot 'lib\common.ps1')
    . (Join-Path $script:CoreRoot 'lib\configuration.ps1')
    $config = Resolve-NwConfiguration -CoreRoot $script:CoreRoot -MachineRoot (Join-Path $Root 'machine')
    $sources = @{}

    foreach ($id in $config['Packages'].Keys) {
        $package = $config['Packages'][$id]
        $source = 'winget'
        if ($package.ContainsKey('Source')) { $source = $package['Source'] }
        $version = '1.0'
        if ($package.ContainsKey('Version') -and $package['Version']) { $version = $package['Version'] }
        if (-not $sources.ContainsKey($source)) { $sources[$source] = @() }
        $sources[$source] += @{ PackageIdentifier = $id; Version = $version }
    }

    $document = @{ Sources = @($sources.Keys | ForEach-Object { @{ SourceDetails = @{ Name = $_ }; Packages = $sources[$_] } }) }
    $path = Join-Path $Root 'installed-export.json'
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $document -Depth 6))
    return $path
}
