# Gallery feed selection, the local test gallery and package reading.

. (Join-Path $script:CoreRoot 'lib\common.ps1')
. (Join-Path $script:CoreRoot 'lib\configuration.ps1')
. (Join-Path $script:CoreRoot 'lib\version.ps1')
. (Join-Path $script:CoreRoot 'lib\gallery.ps1')

function New-TestFeed {
    param([object[]]$Entries)

    $body = foreach ($entry in $Entries) {
        "<entry><title type=`"text`">$($entry[0])</title><m:properties><d:Id>$($entry[0])</d:Id><d:Version>$($entry[1])</d:Version><d:IsPrerelease m:type=`"Edm.Boolean`">$($entry[2])</d:IsPrerelease></m:properties></entry>"
    }

    return '<?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata">' + ($body -join '') + '</feed>'
}

Test 'the feed selection takes the entry with the equal Id and ignores case' {
    $feed = New-TestFeed @(@('PSReadLine.Extra', '9.0.0', 'false'), @('PSReadLine', '2.4.5', 'false'))
    Assert-True ((Select-NwGalleryEntry -FeedXml $feed -Name 'psreadline') -eq '2.4.5') 'The selection took another entry.'
    $similar = 'F' + [char]0x00AD + 'oo'
    Assert-Throws { Select-NwGalleryEntry -FeedXml (New-TestFeed @(, @($similar, '1.0', 'false'))) -Name 'Foo' } 'has 0 stable latest entries'
    Assert-Throws { Select-NwGalleryEntry -FeedXml (New-TestFeed @(, @('PSReadLine.Extra', '9.0.0', 'false'))) -Name 'PSReadLine' } 'has 0 stable latest entries'
    Assert-Throws { Select-NwGalleryEntry -FeedXml (New-TestFeed @(, @('PSReadLine', '3.0.0-beta1', 'true'))) -Name 'PSReadLine' } 'prerelease'
    Assert-Throws { Select-NwGalleryEntry -FeedXml (New-TestFeed @(, @('PSReadLine', 'invalid', 'false'))) -Name 'PSReadLine' } 'invalid version'
}

Test 'the local gallery skips other file names and rejects two equal versions' {
    $gallery = Join-Path (New-TestRoot) 'gallery'
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.0' | Out-Null
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.2' | Out-Null
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '9.0' -File 'latest' | Out-Null
    New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '9.1' -File '9.1-beta' | Out-Null
    New-TestModulePackage -Gallery $gallery -Id 'Foo.Bar' -Version '5.0' | Out-Null
    $saved = $env:NACRE_WINDOWS_GALLERY
    $env:NACRE_WINDOWS_GALLERY = $gallery

    try {
        Assert-True ((Get-NwGalleryLatestVersion 'Foo') -eq '1.2') 'The newest version is not 1.2.'
        New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.2.0' | Out-Null
        Assert-Throws { Get-NwGalleryLatestVersion 'Foo' } 'two files of version 1\.2\.0\.0'
    } finally {
        $env:NACRE_WINDOWS_GALLERY = $saved
    }
}

Test 'a package whose groups give one dependency disjoint ranges fails the read' {
    $gallery = Join-Path (New-TestRoot) 'gallery'
    $dependencies = '<group targetFramework="net6.0"><dependency id="Bar" version="[2.0,)" /></group><group><dependency id="bar" version="(,1.0)" /></group>'
    $path = New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.0' -Dependencies $dependencies
    Assert-Throws { Read-NwModulePackage $path } "needs 'Bar' in ranges that share no version: \(,1\.0\), \[2\.0,\)"
}

Test 'a dependency id with an ignorable character fails the package read' {
    $gallery = Join-Path (New-TestRoot) 'gallery'
    $dependencies = '<dependency id="Bar" version="1.0" /><dependency id="Ba' + [char]0x00AD + 'r" version="2.0" />'
    $path = New-TestModulePackage -Gallery $gallery -Id 'Foo' -Version '1.0' -Dependencies $dependencies
    Assert-Throws { Read-NwModulePackage $path } 'has an invalid id.'
}
