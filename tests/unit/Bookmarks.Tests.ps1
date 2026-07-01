#Requires -Version 5.1

# Unit tests for ConvertTo-BrowserBookmarkPolicy (setup.ps1) - the pure builder that turns the
# $Bookmarks config into Chrome/Edge ManagedBookmarks JSON and Firefox policies.json. setup.ps1 is
# dot-sourced with -LoadOnly, so these tests touch no registry or filesystem state. URLs here are
# placeholders (10.0.0.1) - never the real internal IP, since this repo is public.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\setup.ps1') -LoadOnly

    $script:TwoBookmarks = @(
        @{ Name = 'Cavok'; Url = 'https://hbr.cavok.in/hbr' },
        @{ Name = 'TOTVS'; Url = 'https://10.0.0.1:1234/webapp/' }
    )
}

Describe 'ConvertTo-BrowserBookmarkPolicy' {
    Context 'Chrome/Edge ManagedBookmarks JSON' {
        BeforeAll {
            $result   = ConvertTo-BrowserBookmarkPolicy -Bookmarks $script:TwoBookmarks
            $chromium = $result.ChromiumJson | ConvertFrom-Json
        }

        It 'produces a JSON array with one entry per bookmark' {
            @($chromium).Count | Should -Be 2
        }
        It 'maps Name/Url to the name/url keys, in order' {
            $chromium[0].name | Should -BeExactly 'Cavok'
            $chromium[0].url  | Should -BeExactly 'https://hbr.cavok.in/hbr'
            $chromium[1].name | Should -BeExactly 'TOTVS'
            $chromium[1].url  | Should -BeExactly 'https://10.0.0.1:1234/webapp/'
        }
        It 'exposes only the name and url keys (managed-bookmark shape)' {
            ($chromium[0].PSObject.Properties.Name | Sort-Object) | Should -Be @('name', 'url')
        }
    }

    Context 'Firefox policies.json' {
        BeforeAll {
            $result  = ConvertTo-BrowserBookmarkPolicy -Bookmarks $script:TwoBookmarks
            $firefox = $result.FirefoxJson | ConvertFrom-Json
        }

        It 'nests the bookmarks under policies.Bookmarks' {
            @($firefox.policies.Bookmarks).Count | Should -Be 2
        }
        It 'maps Name/Url to Title/URL and pins to the toolbar' {
            $firefox.policies.Bookmarks[0].Title     | Should -BeExactly 'Cavok'
            $firefox.policies.Bookmarks[0].URL       | Should -BeExactly 'https://hbr.cavok.in/hbr'
            $firefox.policies.Bookmarks[0].Placement | Should -BeExactly 'toolbar'
        }
    }

    Context 'single bookmark (PS 5.1 array-collapse guard)' {
        BeforeAll {
            $one = ConvertTo-BrowserBookmarkPolicy -Bookmarks @(@{ Name = 'Solo'; Url = 'https://solo.example/' })
        }

        It 'still emits a JSON array for Chrome/Edge' {
            $one.ChromiumJson | Should -Match '^\['
            @($one.ChromiumJson | ConvertFrom-Json).Count | Should -Be 1
        }
        It 'still emits a Bookmarks array for Firefox' {
            @(($one.FirefoxJson | ConvertFrom-Json).policies.Bookmarks).Count | Should -Be 1
        }
    }
}
