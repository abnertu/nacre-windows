#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'PSScriptAnalyzer'; RequiredVersion = '1.25.0' }
<#
.SYNOPSIS
    Format every PowerShell file in the repository.
.DESCRIPTION
    Invoke-Formatter applies PSScriptAnalyzerSettings.psd1. Then an AST pass
    applies the blank-line rules that PSScriptAnalyzer does not have:

    - Remove blank lines at the start and the end of a file and a block.
    - Keep at most one blank line in a row.
    - Put one blank line before and after a function definition.
    - Put one blank line after a param block that spans lines.
    - Put one blank line before and after a statement that spans lines.

    A comment directly above a statement belongs to that statement. The
    first and the last statement of a block get no padding.

    -Check changes nothing. It lists each file that is not formatted and
    exits with code 1.
.EXAMPLE
    pwsh -NoProfile -File scripts/format.ps1 -Check
#>
[CmdletBinding()]
param([switch]$Check)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'

# Return the numbers of the lines that hold only comments.
function Get-CommentLines {
    param([System.Management.Automation.Language.Token[]]$Tokens)
    $comment = @{}
    $code = @{}

    foreach ($token in $Tokens) {
        $kind = $token.Kind
        if ($kind -eq 'NewLine' -or $kind -eq 'LineContinuation' -or $kind -eq 'EndOfInput') { continue }
        $lines = $token.Extent.StartLineNumber..$token.Extent.EndLineNumber

        foreach ($line in $lines) {
            if ($kind -eq 'Comment') { $comment[$line] = $true } else { $code[$line] = $true }
        }
    }

    $result = @{}

    foreach ($line in $comment.Keys) {
        if (-not $code.ContainsKey($line)) { $result[$line] = $true }
    }

    return $result
}

# Return the first line of a statement, including the comment lines
# directly above it.
function Get-LeadingLine {
    param([int]$Line, [hashtable]$CommentLines)
    while ($CommentLines.ContainsKey($Line - 1)) { $Line-- }
    return $Line
}

function Test-MultiLine {
    param([System.Management.Automation.Language.Ast]$Ast)
    return $Ast.Extent.StartLineNumber -ne $Ast.Extent.EndLineNumber
}

# Return the statement lists to pad, each as an ordered list of nodes. A
# param block is the first node of the body that follows it.
function Get-StatementLists {
    param([System.Management.Automation.Language.Ast]$Ast)
    $lists = @()

    foreach ($block in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.NamedBlockAst] }, $true)) {
        $script = $block.Parent
        $nodes = @()
        $first = @($script.BeginBlock, $script.ProcessBlock, $script.EndBlock | Where-Object { $_ })[0]
        if ($script.ParamBlock -and [object]::ReferenceEquals($block, $first)) { $nodes += $script.ParamBlock }
        $lists += , ($nodes + @($block.Statements))
    }

    foreach ($block in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StatementBlockAst] }, $true)) {
        # Elements of @() and $() are values, not code sections.
        $parent = $block.Parent
        if ($parent -is [System.Management.Automation.Language.ArrayExpressionAst]) { continue }
        if ($parent -is [System.Management.Automation.Language.SubExpressionAst]) { continue }
        $lists += , @($block.Statements)
    }

    return , $lists
}

function Format-BlankLines {
    param([string]$Text)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot parse: $($errors[0].Message)" }
    $lines = $Text -split "`n"
    $commentLines = Get-CommentLines $tokens

    # Line numbers are 1-based. $insert holds the lines that get a blank
    # line above them; $remove holds the blank lines to drop.
    $insert = @{}
    $remove = @{}
    $isBlank = { param($n) $n -ge 1 -and $n -le $lines.Count -and $lines[$n - 1].Trim() -eq '' }

    foreach ($nodes in (Get-StatementLists $ast)) {
        for ($i = 1; $i -lt $nodes.Count; $i++) {
            $previous = $nodes[$i - 1]
            $next = $nodes[$i]
            $end = $previous.Extent.EndLineNumber
            $start = Get-LeadingLine $next.Extent.StartLineNumber $commentLines
            if ($start -le $end) { continue }

            $pad = ($previous -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                $next -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                (Test-MultiLine $previous) -or (Test-MultiLine $next))

            $hasBlank = $false
            for ($n = $end + 1; $n -lt $start; $n++) { if (& $isBlank $n) { $hasBlank = $true } }
            if ($pad -and -not $hasBlank) { $insert[$start] = $true }
        }
    }

    # Blank lines after an opening brace and before a closing brace.
    $braceTypes = @(
        [System.Management.Automation.Language.StatementBlockAst]
        [System.Management.Automation.Language.ScriptBlockAst]
        [System.Management.Automation.Language.HashtableAst]
    )

    $braces = $ast.FindAll({ param($node) $braceTypes -contains $node.GetType() }, $true)

    foreach ($block in $braces) {
        $extent = $block.Extent
        if ($extent.StartLineNumber -eq $extent.EndLineNumber) { continue }
        if (-not $extent.Text.EndsWith('}')) { continue }
        for ($n = $extent.StartLineNumber + 1; (& $isBlank $n) -and $n -lt $extent.EndLineNumber; $n++) { $remove[$n] = $true }
        for ($n = $extent.EndLineNumber - 1; (& $isBlank $n) -and $n -gt $extent.StartLineNumber; $n--) { $remove[$n] = $true }
    }

    # A string or a comment that spans lines keeps its inner lines.
    $verbatim = @{}

    foreach ($token in $tokens) {
        $extent = $token.Extent
        if ($token.Kind -eq 'NewLine' -or $extent.StartLineNumber -eq $extent.EndLineNumber) { continue }
        foreach ($n in ($extent.StartLineNumber + 1)..$extent.EndLineNumber) { $verbatim[$n] = $true }
    }

    $output = New-Object System.Collections.Generic.List[string]

    for ($n = 1; $n -le $lines.Count; $n++) {
        $line = $lines[$n - 1]

        if ($verbatim.ContainsKey($n)) {
            $output.Add($line)
            continue
        }

        if ($remove.ContainsKey($n)) { continue }

        if ($line.Trim() -eq '') {
            # Keep one blank line in a row, and none at the start.
            if ($output.Count -eq 0 -or $output[$output.Count - 1] -eq '') { continue }
            $output.Add('')
            continue
        }

        if ($insert.ContainsKey($n) -and $output.Count -gt 0 -and $output[$output.Count - 1] -ne '') {
            $output.Add('')
        }

        $output.Add($line)
    }

    while ($output.Count -gt 0 -and $output[$output.Count - 1] -eq '') { $output.RemoveAt($output.Count - 1) }
    return (($output -join "`n") + "`n")
}

function Format-NwScript {
    param([string]$Text)
    $text = $Text.Replace("`r`n", "`n")
    $text = Invoke-Formatter -ScriptDefinition $text -Settings $settings
    $text = $text.Replace("`r`n", "`n")
    return (Format-BlankLines $text)
}

# -Include is ignored with -LiteralPath in Windows PowerShell 5.1.
$files = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { @('.ps1', '.psd1') -contains $_.Extension -and $_.FullName -notmatch '\\\.git\\' } |
    Sort-Object FullName

$unformatted = @()
$encoding = New-Object System.Text.UTF8Encoding($false)

foreach ($file in $files) {
    $original = [System.IO.File]::ReadAllText($file.FullName)
    $formatted = Format-NwScript $original
    if ($formatted -ceq $original) { continue }
    $relative = $file.FullName.Substring($root.Length + 1)
    $unformatted += $relative

    if (-not $Check) {
        [System.IO.File]::WriteAllText($file.FullName, $formatted, $encoding)
        Write-Host "Formatted $relative"
    }
}

if ($Check -and $unformatted.Count -gt 0) {
    foreach ($relative in $unformatted) { Write-Host "Not formatted: $relative" }
    Write-Host 'Run scripts/format.ps1 to format them.'
    exit 1
}

exit 0
