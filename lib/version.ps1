# Versions and NuGet version ranges of PowerShell Gallery packages. Only
# stable versions of 2 to 4 numeric parts are supported.
Set-StrictMode -Version Latest

function Test-NwVersionText {
    param($Text)
    if ($Text -isnot [string] -or $Text -cnotmatch '^[0-9]+(\.[0-9]+){1,3}\z') { return $false }

    [version]$parsed = $null
    return [version]::TryParse($Text, [ref]$parsed)
}

# Missing parts are 0, so '2.4' equals '2.4.0.0'.
function ConvertTo-NwVersion {
    param($Text)
    if (-not (Test-NwVersionText $Text)) { throw "'$Text' is not a version of 2 to 4 numeric parts, such as '2.4.5'." }
    $parts = @(([string]$Text).Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return (New-Object System.Version($parts[0], $parts[1], $parts[2], $parts[3]))
}

# A range is @{ Min; MinInclusive; Max; MaxInclusive }. A $null bound is open.
function ConvertTo-NwVersionRange {
    param($Text)
    if (-not ($Text -is [string])) { throw 'A version range must be a string.' }
    $trimmed = $Text.Trim()
    if ($trimmed.Length -eq 0) { return @{ Min = $null; MinInclusive = $false; Max = $null; MaxInclusive = $false } }

    if (Test-NwVersionText $trimmed) {
        return @{ Min = (ConvertTo-NwVersion $trimmed); MinInclusive = $true; Max = $null; MaxInclusive = $false }
    }

    if ($trimmed -match '^\[\s*([^,\s\[\]\(\)]+)\s*\]$') {
        $version = ConvertTo-NwVersion $Matches[1]
        return @{ Min = $version; MinInclusive = $true; Max = $version; MaxInclusive = $true }
    }

    if ($trimmed -notmatch '^([\[\(])\s*([^,\s\[\]\(\)]*)\s*,\s*([^,\s\[\]\(\)]*)\s*([\]\)])$') {
        throw "'$Text' is not a NuGet version range."
    }

    $lower = $Matches[2]
    $upper = $Matches[3]
    $range = @{ Min = $null; MinInclusive = ($Matches[1] -eq '['); Max = $null; MaxInclusive = ($Matches[4] -eq ']') }
    if (-not $lower -and -not $upper) { throw "'$Text' has no bound." }
    if (-not $lower -and $range.MinInclusive) { throw "'$Text' has an open lower bound with '['." }
    if (-not $upper -and $range.MaxInclusive) { throw "'$Text' has an open upper bound with ']'." }
    if ($lower) { $range.Min = ConvertTo-NwVersion $lower }
    if ($upper) { $range.Max = ConvertTo-NwVersion $upper }
    if (-not (Test-NwRangeBounds $range)) { throw "'$Text' holds no version." }
    return $range
}

function Test-NwRangeBounds {
    param([System.Collections.IDictionary]$Range)
    $first = $Range.Min

    if ($null -eq $first) {
        $first = [version]'0.0.0.0'
    } elseif (-not $Range.MinInclusive) {
        $parts = @($first.Major, $first.Minor, $first.Build, $first.Revision)
        $index = 3

        while ($index -ge 0 -and $parts[$index] -eq [int]::MaxValue) {
            $parts[$index] = 0
            $index--
        }

        if ($index -lt 0) { return $false }

        $parts[$index]++
        $first = [version]($parts -join '.')
    }

    return (Test-NwVersionInRange $first $Range)
}

function Test-NwVersionInRange {
    param([System.Version]$Version, [System.Collections.IDictionary]$Range)

    if ($null -ne $Range.Min) {
        if ($Version -lt $Range.Min -or ($Version -eq $Range.Min -and -not $Range.MinInclusive)) { return $false }
    }

    if ($null -ne $Range.Max) {
        if ($Version -gt $Range.Max -or ($Version -eq $Range.Max -and -not $Range.MaxInclusive)) { return $false }
    }

    return $true
}

# True when one version can be inside every range.
function Test-NwRangeIntersection {
    param([System.Collections.IDictionary[]]$Ranges)
    $common = @{ Min = $null; MinInclusive = $false; Max = $null; MaxInclusive = $false }

    foreach ($range in $Ranges) {
        if ($null -ne $range.Min) {
            if ($null -eq $common.Min -or $range.Min -gt $common.Min) {
                $common.Min = $range.Min
                $common.MinInclusive = $range.MinInclusive
            } elseif ($range.Min -eq $common.Min) {
                $common.MinInclusive = $common.MinInclusive -and $range.MinInclusive
            }
        }

        if ($null -ne $range.Max) {
            if ($null -eq $common.Max -or $range.Max -lt $common.Max) {
                $common.Max = $range.Max
                $common.MaxInclusive = $range.MaxInclusive
            } elseif ($range.Max -eq $common.Max) {
                $common.MaxInclusive = $common.MaxInclusive -and $range.MaxInclusive
            }
        }
    }

    return (Test-NwRangeBounds $common)
}
