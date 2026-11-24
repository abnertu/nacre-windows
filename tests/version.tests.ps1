# Versions and NuGet ranges of Gallery modules.

. (Join-Path $script:CoreRoot 'lib\common.ps1')
. (Join-Path $script:CoreRoot 'lib\version.ps1')

function Test-RangeText {
    param([string]$Range, [string]$Version)
    return (Test-NwVersionInRange (ConvertTo-NwVersion $Version) (ConvertTo-NwVersionRange $Range))
}

Test 'versions of 2 to 4 parts compare with missing parts as 0' {
    Assert-True ((ConvertTo-NwVersion '2.4') -eq (ConvertTo-NwVersion '2.4.0.0')) '2.4 differs from 2.4.0.0.'
    Assert-True ((ConvertTo-NwVersion '2.10') -gt (ConvertTo-NwVersion '2.9.9')) '2.10 is not above 2.9.9.'

    Assert-True ((ConvertTo-NwVersion '2147483647.0').Major -eq [int]::MaxValue) 'The largest version part was rejected.'

    foreach ($text in @('2', '2.4.0.0.1', '2.4.0-beta0', '2.*', '2147483648.0', ' 2.4', 'v2.4', ('2.4' + [char]10), ([string][char]0x0662 + '.4'))) {
        $failed = $false
        try { ConvertTo-NwVersion $text | Out-Null } catch { $failed = $true }
        Assert-True $failed "'$text' was accepted as a version."
    }
}

Test 'NuGet ranges accept each form and reject the others' {
    $inside = @{
        ''             = '0.1'
        '1.0'          = '1.0'
        '[1.0]'        = '1.0.0.0'
        '[1.0,2.0]'    = '2.0'
        '[1.0,2.0)'    = '1.9.9.9'
        '(1.0,2.0]'    = '1.0.0.1'
        '(1.0,2.0)'    = '1.5'
        '[5.5.5, )'    = '5.5.5'
        '(1.0,)'       = '1.0.1'
        '(,2.0]'       = '2.0'
        '( , 2.0.0.0)' = '1.9'
    }

    foreach ($range in $inside.Keys) {
        Assert-True (Test-RangeText $range $inside[$range]) "'$($inside[$range])' is outside '$range'."
    }

    $outside = @{ '1.0' = '0.9'; '[1.0]' = '1.0.1'; '[1.0,2.0)' = '2.0'; '(1.0,2.0]' = '1.0'; '(,2.0)' = '2.0.0.0'; '(1.0,)' = '1.0' }

    foreach ($range in $outside.Keys) {
        Assert-True (-not (Test-RangeText $range $outside[$range])) "'$($outside[$range])' is inside '$range'."
    }

    $invalid = @(([string][char]0x00AD), '[1.0-beta,)', '1.*', '[1.0,', '[,2.0]', '[1.0,]', '(,)', '[2.0,1.0]', '(1.0,1.0)', '[1.0,1.0)', '(1.0.0.0,1.0.0.1)', '(,0.0)', '(2147483647.2147483647.2147483647.2147483647,)', '1.0,2.0', '[1.0,2.0,3.0]')

    foreach ($range in $invalid) {
        $failed = $false
        try { ConvertTo-NwVersionRange $range | Out-Null } catch { $failed = $true }
        Assert-True $failed "'$range' was accepted as a range."
    }
}

Test 'range intersection finds a common version or none' {
    $cases = @(
        @{ Ranges = @('(,1.0)', '[1.0,)'); Common = $false }
        @{ Ranges = @('[1.0,2.0)', '[2.0.0.0,)'); Common = $false }
        @{ Ranges = @('[1.0]', '[1.0,)'); Common = $true }
        @{ Ranges = @('[1.0,2.0]', '[2.0,3.0]'); Common = $true }
        @{ Ranges = @('', '1.5'); Common = $true }
    )

    foreach ($case in $cases) {
        [System.Collections.IDictionary[]]$ranges = @($case.Ranges | ForEach-Object { ConvertTo-NwVersionRange $_ })
        $common = Test-NwRangeIntersection $ranges
        Assert-True ($common -eq $case.Common) "Intersection of $($case.Ranges -join ' and ') is $common."
    }
}
