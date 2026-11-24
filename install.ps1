# Install or upgrade nacre-windows. Run the newest release's copy:
#   irm https://github.com/abnertu/nacre-windows/releases/latest/download/install.ps1 | iex
#
# Without a machine repository, it clones NACRE_REPO into the checkout, or
# creates one from the release's template. Then it runs the release's
# template wrapper: upgrade self for that machine, which pins the newest core
# on the machine's channel, plans, asks and switches.
#
# Environment:
#   NACRE_REPO  machine repository to clone into a new checkout
#   NACRE_DIR   checkout; default ~/.config/nacre. The machine is the
#               checkout or its windows/ subdirectory.
#   NACRE_YES   1: switch without a question
#
# Everything runs in one script block, so `iex` leaves the caller's session,
# preferences and strict mode as they were.

& {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    function Find-Machine {
        param([string]$Checkout)

        foreach ($root in @($Checkout, (Join-Path $Checkout 'windows'))) {
            if (Test-Path -LiteralPath (Join-Path $root 'machine.psd1')) { return $root }
        }

        return $null
    }

    function Invoke-GitHubJson {
        param([string]$Api, [string]$Path)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'nacre-windows' }
        $content = (Invoke-WebRequest -UseBasicParsing -Uri "$Api/$Path" -Headers $headers).Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        return (ConvertFrom-Json ([string]$content))
    }

    $temporary = $null

    try {
        $repo = 'abnertu/nacre-windows'
        $api = 'https://api.github.com'
        if ($env:NACRE_WINDOWS_GITHUB_API) { $api = $env:NACRE_WINDOWS_GITHUB_API.TrimEnd('/') }
        $archiveBase = 'https://github.com'
        if ($env:NACRE_WINDOWS_GITHUB_ARCHIVE) { $archiveBase = $env:NACRE_WINDOWS_GITHUB_ARCHIVE.TrimEnd('/') }
        $userHome = $HOME
        if ($env:NACRE_WINDOWS_HOME) { $userHome = $env:NACRE_WINDOWS_HOME }

        # Preconditions, before any write.
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) { throw 'WinGet is missing. Install WinGet 1.11 or later, then run this again.' }
        $wingetVersion = [string](& winget --version)

        if ($wingetVersion -notmatch 'v?(\d+)\.(\d+)' -or [version]"$($Matches[1]).$($Matches[2])" -lt [version]'1.11') {
            throw "WinGet $($wingetVersion.Trim()) is too old. Install WinGet 1.11 or later, then run this again."
        }

        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is missing. Install Git, then run this again.' }

        $checkout = $env:NACRE_DIR
        if (-not $checkout) { $checkout = Join-Path (Join-Path $userHome '.config') 'nacre' }
        # .NET resolves relative paths against another directory than PowerShell.
        $checkout = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($checkout)
        $machine = Find-Machine $checkout

        if (-not $machine -and (Test-Path -LiteralPath $checkout) -and @(Get-ChildItem -LiteralPath $checkout -Force).Count -gt 0) {
            throw "'$checkout' is not empty and holds no machine.psd1, in it or in windows/. Set NACRE_DIR to another checkout."
        }

        # The newest release: its template wrapper runs upgrade self.
        $latest = Invoke-GitHubJson $api "repos/$repo/releases/latest"
        $tag = [string]$latest.tag_name
        $commit = [string](Invoke-GitHubJson $api "repos/$repo/commits/$([Uri]::EscapeDataString($tag))").sha
        if ($commit -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned no commit for $repo $tag." }
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('nacre-windows-install-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary | Out-Null
        $archive = Join-Path $temporary 'core.tar.gz'
        $progress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'

        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$archiveBase/$repo/archive/$commit.tar.gz" -OutFile $archive
        } finally {
            $ProgressPreference = $progress
        }

        & tar.exe -xzf $archive -C $temporary
        if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE." }
        $release = @(Get-ChildItem -LiteralPath $temporary -Directory)
        if ($release.Count -ne 1) { throw 'The release archive has no single top directory.' }
        $template = Join-Path $release[0].FullName 'templates\machine'
        Get-ChildItem -LiteralPath $release[0].FullName -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

        if (-not $machine) {
            if ($env:NACRE_REPO) {
                Write-Host "Cloning $env:NACRE_REPO into $checkout"
                & git clone --quiet $env:NACRE_REPO $checkout
                if ($LASTEXITCODE -ne 0) { throw "git clone $env:NACRE_REPO failed with exit code $LASTEXITCODE." }
                $machine = Find-Machine $checkout
                if (-not $machine) { throw "$env:NACRE_REPO holds no machine.psd1, at its root or in windows/." }
            } else {
                Write-Host "Creating a machine repository from the $tag template in $checkout"
                New-Item -ItemType Directory -Force -Path $checkout | Out-Null
                Get-ChildItem -LiteralPath $template -Force | Copy-Item -Destination $checkout -Recurse
                & git -C $checkout init --quiet
                if ($LASTEXITCODE -ne 0) { throw "git init failed with exit code $LASTEXITCODE." }
                & git -C $checkout add --all
                if ($LASTEXITCODE -ne 0) { throw "git add failed with exit code $LASTEXITCODE." }
                $machine = $checkout
            }
        } elseif ($env:NACRE_REPO) {
            $origin = ''

            if (Test-Path -LiteralPath (Join-Path $checkout '.git')) {
                # config --get prints nothing and exits 1 for a missing remote.
                $origin = (@(& git -C $checkout config --get remote.origin.url) -join '').Trim()
            }

            if ($origin -ne $env:NACRE_REPO) { Write-Warning "$checkout has origin '$origin', not NACRE_REPO '$env:NACRE_REPO'. Upgrading it." }
        }

        $wrapper = Join-Path $template 'nacre.ps1'
        $own = Join-Path $machine 'nacre.ps1'

        if (-not (Test-Path -LiteralPath $own) -or ([IO.File]::ReadAllText($own).Replace("`r`n", "`n") -ne [IO.File]::ReadAllText($wrapper).Replace("`r`n", "`n"))) {
            Write-Warning "$own differs from the $tag template. Copy $repo/templates/machine/nacre.ps1 at $tag over it."
        }

        $policy = [string](Get-ExecutionPolicy)

        if (@('Unrestricted', 'RemoteSigned', 'Bypass') -contains $policy) {
            # In this process, as the nacre profile function runs it: WinGet keeps
            # this console's mode, so its progress, colors and encoding work.
            $wrapperArguments = @{ Command = 'upgrade'; Names = @('self'); MachineRoot = $machine }
            if ($env:NACRE_YES -eq '1') { $wrapperArguments['Yes'] = $true }
            & $wrapper @wrapperArguments
            if ($LASTEXITCODE -ne 0) { throw "upgrade self failed with exit code $LASTEXITCODE." }
        } else {
            # The policy blocks script files here; run a RemoteSigned process.
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned')
            $nonInteractive = [Console]::IsInputRedirected -or @([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni(n(t(e(r(a(c(t(i(v(e)?)?)?)?)?)?)?)?)?)?$' }).Count -gt 0
            if ($nonInteractive) { $arguments += '-NonInteractive' }
            $arguments += @('-File', $wrapper, 'upgrade', 'self', '-MachineRoot', $machine)
            if ($env:NACRE_YES -eq '1') { $arguments += '-Yes' }
            # The console host, also under the ISE: pwsh for 7, powershell.exe for 5.1.
            $shell = Join-Path $PSHOME 'powershell.exe'
            if ($PSVersionTable.PSEdition -eq 'Core') { $shell = (Get-Process -Id $PID).Path }
            $quoted = @($arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
            $process = Start-Process -FilePath $shell -ArgumentList $quoted -NoNewWindow -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "upgrade self failed with exit code $($process.ExitCode)." }
        }

        Write-Host "nacre-windows $tag is ready in $machine."
    } catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
    } finally {
        if ($temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
