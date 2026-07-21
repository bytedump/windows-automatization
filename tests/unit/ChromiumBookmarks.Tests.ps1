#Requires -Version 5.1

# Unit tests for the Chrome/Edge profile-Bookmarks seeding in phase-b.ps1:
#   - ConvertTo-ChromiumBookmarkFile (pure): builds the profile Bookmarks JSON with links LOOSE on
#     the bar (roots.bookmark_bar.children), no checksum, PS 5.1 array-collapse-safe.
#   - Set-ChromiumBookmarks (file I/O redirected to TestDrive): writes Chrome + Edge, skips if the
#     file already exists, no-op on empty input.
# phase-b.ps1 is dot-sourced with -LoadOnly so no real profile/registry is touched. URLs are
# placeholders (10.0.0.1) - never the real internal IP, since this repo is public.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\phase-b.ps1') -LoadOnly

    $script:TwoBookmarks = @(
        @{ Name = 'Intranet'; Url = 'https://10.0.0.1/portal' },
        @{ Name = 'WebApp';   Url = 'https://10.0.0.1:1234/webapp/' }
    )
}

Describe 'ConvertTo-ChromiumBookmarkFile' {
    BeforeAll {
        $script:doc = ConvertTo-ChromiumBookmarkFile -Bookmarks $script:TwoBookmarks | ConvertFrom-Json
    }

    It 'puts the links LOOSE on the bar (bookmark_bar.children), not in "other"' {
        @($script:doc.roots.bookmark_bar.children) | Should -HaveCount 2
        @($script:doc.roots.other.children)        | Should -HaveCount 0
        @($script:doc.roots.synced.children)       | Should -HaveCount 0
    }

    It 'maps Name/Url to name/url, type url, in order' {
        $script:doc.roots.bookmark_bar.children[0].name | Should -BeExactly 'Intranet'
        $script:doc.roots.bookmark_bar.children[0].url  | Should -BeExactly 'https://10.0.0.1/portal'
        $script:doc.roots.bookmark_bar.children[0].type | Should -BeExactly 'url'
        $script:doc.roots.bookmark_bar.children[1].name | Should -BeExactly 'WebApp'
    }

    It 'gives every entry a unique id and a non-empty guid' {
        $ids = @($script:doc.roots.bookmark_bar.children | ForEach-Object { $_.id })
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($c in $script:doc.roots.bookmark_bar.children) {
            $c.guid | Should -Not -BeNullOrEmpty
        }
    }

    It 'writes NO checksum key (fresh profile - Chromium recomputes it)' {
        $script:doc.PSObject.Properties.Name | Should -Not -Contain 'checksum'
    }

    It 'still emits a children ARRAY for a single link (PS 5.1 collapse guard)' {
        $one = ConvertTo-ChromiumBookmarkFile -Bookmarks @(@{ Name = 'Solo'; Url = 'https://solo.example/' }) | ConvertFrom-Json
        @($one.roots.bookmark_bar.children)      | Should -HaveCount 1
        $one.roots.bookmark_bar.children[0].name | Should -BeExactly 'Solo'
    }

    It 'produces a valid doc with empty children for empty input' {
        $empty = ConvertTo-ChromiumBookmarkFile -Bookmarks @() | ConvertFrom-Json
        @($empty.roots.bookmark_bar.children) | Should -HaveCount 0
        $empty.version | Should -Be 1
    }
}

Describe 'Set-ChromiumBookmarks (profile seeding)' {
    BeforeEach {
        $script:lad = Join-Path $TestDrive 'LocalAppData'
        Remove-Item -LiteralPath $lad -Recurse -Force -ErrorAction SilentlyContinue
        $script:chromeFile = Join-Path $lad 'Google\Chrome\User Data\Default\Bookmarks'
        $script:edgeFile   = Join-Path $lad 'Microsoft\Edge\User Data\Default\Bookmarks'
    }

    It 'seeds both Chrome and Edge with the links under bookmark_bar' {
        Set-ChromiumBookmarks -Bookmarks $script:TwoBookmarks -LocalAppData $lad

        foreach ($f in $chromeFile, $edgeFile) {
            Test-Path -LiteralPath $f | Should -BeTrue
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            @($j.roots.bookmark_bar.children) | Should -HaveCount 2
            $j.roots.bookmark_bar.children[0].name | Should -BeExactly 'Intranet'
        }
    }

    It 'writes the file WITHOUT a UTF-8 BOM' {
        Set-ChromiumBookmarks -Bookmarks $script:TwoBookmarks -LocalAppData $lad
        $bytes = [System.IO.File]::ReadAllBytes($chromeFile)
        # EF BB BF is the UTF-8 BOM; Chromium rejects it. First byte must be '{'.
        $bytes[0] | Should -Be ([byte][char]'{')
    }

    It 'does NOT clobber an existing Bookmarks file (skip-if-exists guard)' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $chromeFile) -Force | Out-Null
        Set-Content -LiteralPath $chromeFile -Value 'ORIGINAL' -Encoding UTF8

        Set-ChromiumBookmarks -Bookmarks $script:TwoBookmarks -LocalAppData $lad

        (Get-Content -LiteralPath $chromeFile -Raw).TrimEnd() | Should -BeExactly 'ORIGINAL'
        # Edge had no file, so it still gets seeded.
        Test-Path -LiteralPath $edgeFile | Should -BeTrue
    }

    It 'is a no-op when no bookmarks are selected' {
        Set-ChromiumBookmarks -Bookmarks @() -LocalAppData $lad
        Test-Path -LiteralPath $chromeFile | Should -BeFalse
        Test-Path -LiteralPath $edgeFile   | Should -BeFalse
    }
}
