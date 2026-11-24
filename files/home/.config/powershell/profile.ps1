# nacre-windows PowerShell profile for Windows PowerShell 5.1 and PowerShell 7.
# Dot-source it from $PROFILE.CurrentUserCurrentHost of each host. Put
# personal additions in ~/.config/powershell/profile.d/*.ps1.
# Keep this file ASCII: Windows PowerShell 5.1 misreads UTF-8 without a BOM.

Import-Module PSReadLine -ErrorAction SilentlyContinue

try {
    Set-PSReadLineOption -PredictionSource History -ErrorAction Stop
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineKeyHandler -Chord UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Chord DownArrow -Function HistorySearchForward
} catch {
    # Older PSReadLine versions have no prediction support.
}

$nacreProfileDirectory = Join-Path $PSScriptRoot 'profile.d'

if (Test-Path -LiteralPath $nacreProfileDirectory) {
    foreach ($nacreProfileFile in Get-ChildItem -LiteralPath $nacreProfileDirectory -Filter '*.ps1' | Sort-Object Name) {
        . $nacreProfileFile.FullName
    }
}

Remove-Variable -Name nacreProfileDirectory, nacreProfileFile -ErrorAction SilentlyContinue

# nacre runs the machine wrapper from any directory. The checkout is
# NACRE_DIR, else ~/.config/nacre; the machine is the checkout or its
# windows/ subdirectory, whichever holds machine.psd1.
function nacre {
    $nacreHome = $HOME
    if ($env:NACRE_WINDOWS_HOME) { $nacreHome = $env:NACRE_WINDOWS_HOME }
    $checkout = $env:NACRE_DIR
    if (-not $checkout) { $checkout = Join-Path (Join-Path $nacreHome '.config') 'nacre' }
    $tried = @($checkout, (Join-Path $checkout 'windows'))

    foreach ($root in $tried) {
        if (Test-Path -LiteralPath (Join-Path $root 'machine.psd1')) {
            & (Join-Path $root 'nacre.ps1') @args
            return
        }
    }

    Write-Error "No nacre-windows machine in '$($tried -join "' or '")'. Set NACRE_DIR to the checkout."
}

# Starship reads ~/.config/starship.toml by default.
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (& starship init powershell)
}
