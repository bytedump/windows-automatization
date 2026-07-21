#Requires -Version 5.1

# Unit tests for the pure bookmark/wallpaper helpers in setup.ps1: ConvertTo-BrowserBookmarkPolicy
# (Firefox policies.json payload, plus the retained-for-reference Chromium flat shape - Chrome/Edge
# are now seeded per-user in phase-b.ps1, not via managed policy), Select-EnabledBookmarks (per-link
# subset) and Resolve-WallpaperFile (domain->file). setup.ps1 is dot-sourced with -LoadOnly, so these
# tests touch no registry or filesystem state. URLs here are placeholders (10.0.0.1) - never the real
# internal IP, since this repo is public.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\setup.ps1') -LoadOnly

    $script:TwoBookmarks = @(
        @{ Name = 'Intranet'; Url = 'https://10.0.0.1/portal' },
        @{ Name = 'WebPortal'; Url = 'https://10.0.0.1:1234/webapp/' }
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
            $chromium[0].name | Should -BeExactly 'Intranet'
            $chromium[0].url  | Should -BeExactly 'https://10.0.0.1/portal'
            $chromium[1].name | Should -BeExactly 'WebPortal'
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
            $firefox.policies.Bookmarks[0].Title     | Should -BeExactly 'Intranet'
            $firefox.policies.Bookmarks[0].URL       | Should -BeExactly 'https://10.0.0.1/portal'
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

Describe 'Select-EnabledBookmarks' {
    BeforeAll {
        $script:Two = @(
            @{ Name = 'Intranet'; Url = 'https://10.0.0.1/portal' },
            @{ Name = 'WebApp';   Url = 'https://10.0.0.1:1234/webapp/' }
        )
    }

    It 'keeps only the first when flags are @($true, $false)' {
        $r = @(Select-EnabledBookmarks -Bookmarks $script:Two -Flags @($true, $false))
        $r.Count    | Should -Be 1
        $r[0].Name  | Should -BeExactly 'Intranet'
    }

    It 'keeps only the second when flags are @($false, $true)' {
        $r = @(Select-EnabledBookmarks -Bookmarks $script:Two -Flags @($false, $true))
        $r.Count    | Should -Be 1
        $r[0].Name  | Should -BeExactly 'WebApp'
    }

    It 'keeps both, in order, when flags are @($true, $true)' {
        $r = @(Select-EnabledBookmarks -Bookmarks $script:Two -Flags @($true, $true))
        $r.Count    | Should -Be 2
        $r[0].Name  | Should -BeExactly 'Intranet'
        $r[1].Name  | Should -BeExactly 'WebApp'
    }

    It 'returns an empty array when no flag is set' {
        @(Select-EnabledBookmarks -Bookmarks $script:Two -Flags @($false, $false)) | Should -HaveCount 0
    }

    It 'returns empty for a $null bookmark list (no throw)' {
        @(Select-EnabledBookmarks -Bookmarks $null -Flags @($true, $true)) | Should -HaveCount 0
    }

    It 'tolerates more flags than bookmarks without error' {
        $r = @(Select-EnabledBookmarks -Bookmarks $script:Two -Flags @($true, $true, $true))
        $r.Count | Should -Be 2
    }

    It 'tolerates fewer flags than bookmarks (unflagged links are dropped)' {
        $r = @(Select-EnabledBookmarks -Bookmarks $script:Two -Flags @($true))
        $r.Count   | Should -Be 1
        $r[0].Name | Should -BeExactly 'Intranet'
    }
}

Describe 'Resolve-WallpaperFile' {
    BeforeAll {
        $script:Map = @{ 'branch-b.example.com' = 'wallpaper-alt.jpg' }
    }

    It 'returns the mapped file when the domain is in the map' {
        Resolve-WallpaperFile -Domain 'branch-b.example.com' -Map $script:Map -Default 'wallpaper.jpg' |
            Should -BeExactly 'wallpaper-alt.jpg'
    }
    It 'falls back to the default for an unmapped domain' {
        Resolve-WallpaperFile -Domain 'unmapped.example.com' -Map $script:Map -Default 'wallpaper.jpg' |
            Should -BeExactly 'wallpaper.jpg'
    }
    It 'falls back to the default when the map is $null' {
        Resolve-WallpaperFile -Domain 'branch-b.example.com' -Map $null -Default 'wallpaper.jpg' |
            Should -BeExactly 'wallpaper.jpg'
    }
    It 'falls back to the default for an empty domain' {
        Resolve-WallpaperFile -Domain '' -Map $script:Map -Default 'wallpaper.jpg' |
            Should -BeExactly 'wallpaper.jpg'
    }
}
