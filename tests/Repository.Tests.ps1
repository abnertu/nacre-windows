# Windows PowerShell 5.1 reads a BOM-less script as the ANSI code page, so
# a non-ASCII byte changes what the script means there.

Test 'every PowerShell file parses and is ASCII with LF line endings' {
    $problems = @()
    # -Include is ignored with -LiteralPath in Windows PowerShell 5.1.
    $files = Get-ChildItem -LiteralPath $script:CoreRoot -Recurse -File |
        Where-Object { @('.ps1', '.psd1') -contains $_.Extension -and $_.FullName -notmatch '\\\.git\\' }
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { $problems += "$($file.Name): $($errors[0].Message)" }
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) { $problems += "$($file.Name): non-ASCII byte" }
        if (@($bytes | Where-Object { $_ -eq 13 }).Count -gt 0) { $problems += "$($file.Name): CR line ending" }
    }
    Assert-True ($problems.Count -eq 0) ($problems -join "`n")
}
