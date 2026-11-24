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

# Starship reads ~/.config/starship.toml by default.
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (& starship init powershell)
}
