#Requires -Version 5.1

# Unit tests for the pure config.ps1 generator in build-usb.ps1: Format-PsString (escaping),
# ConvertTo-ConfigPs1Content (the serializer), Test-Ipv4, and Import-ConfigDefault. build-usb.ps1
# is dot-sourced with -LoadOnly, so only the pure helpers load — the interactive wizard body and
# the autounattend generation never run. The load-bearing guarantee is round-trip safety: text
# produced by the serializer must dot-source back to the exact values it was given.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\build-usb.ps1') -LoadOnly

    # Dot-source generated config text in an isolated child scope (with $ScriptDir predefined,
    # exactly as setup.ps1 provides it) and return the resulting variables as a hashtable.
    function Get-ConfigRoundTrip {
        param([Parameter(Mandatory)][string]$Text)
        & {
            param($ConfigText)
            $ScriptDir = 'C:\USB'
            . ([scriptblock]::Create($ConfigText))
            $h = @{}
            foreach ($n in 'AdminAccount', 'AdminNewPass', 'UserInitialPass', 'EmailDomains',
                          'StaticGateway', 'StaticPrefixLength', 'DnsServers', 'WallpaperFile',
                          'WallpaperByDomain', 'WifiSSID', 'WifiPass', 'Bookmarks',
                          'PathSignatures', 'PathOffice', 'PathBelarc') {
                # .Value (not -ValueOnly): -ValueOnly enumerates through the pipeline and would
                # collapse a single-element array to a scalar / an empty array to $null.
                $var = Get-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue
                if ($null -ne $var) { $h[$n] = $var.Value }
            }
            $h
        } $Text
    }

    # A full, representative value set (adversarial strings included).
    function New-SampleValues {
        @{
            AdminAccount       = 'setupadmin'
            AdminNewPass       = "adm'in`$pw`"12"    # single quote, $, and double quote
            UserInitialPass    = 'UserInitial123'
            EmailDomains       = @('a.example.com', 'b.example.com')
            StaticGateway      = '10.0.0.1'
            StaticPrefixLength = 24
            DnsServers         = @('8.8.8.8', '8.8.4.4')
            WallpaperFile      = 'wallpaper.jpg'
            WallpaperByDomain  = @{ 'b.example.com' = 'alt.png' }
            WifiSSID           = 'CorpNet'
            WifiPass           = 'wifipass12345'
            Bookmarks          = @(
                @{ Name = "O'Brien & Co"; Url = 'https://one.example/' },
                @{ Name = 'Second';       Url = 'https://two.example/?a=1&b=2' }
            )
        }
    }
}

Describe 'Format-PsString' {
    It 'wraps a plain string in single quotes' {
        Format-PsString 'hello' | Should -BeExactly "'hello'"
    }
    It 'doubles embedded single quotes' {
        Format-PsString "O'Brien" | Should -BeExactly "'O''Brien'"
    }
    It 'leaves $, backtick and double-quote untouched (single quotes do not interpret them)' {
        Format-PsString 'a$b`c"d' | Should -BeExactly "'a`$b``c`"d'"
    }
    It 'encodes an empty string as two single quotes' {
        Format-PsString '' | Should -BeExactly "''"
    }
    It 'produces a literal that evaluates back to the original' {
        $v = "weird '`$`" value"
        (& ([scriptblock]::Create('return ' + (Format-PsString $v)))) | Should -BeExactly $v
    }
}

Describe 'ConvertTo-ConfigPs1Content — validity and the $Path* block' {
    It 'produces text that parses as valid PowerShell' {
        $t = ConvertTo-ConfigPs1Content -Values (New-SampleValues)
        { [scriptblock]::Create($t) } | Should -Not -Throw
    }
    It 'emits the $Path* block referencing $ScriptDir (double-quoted, expands at load)' {
        $t = ConvertTo-ConfigPs1Content -Values (New-SampleValues)
        $t | Should -Match 'PathSignatures\s*=\s*"\$ScriptDir'
        (Get-ConfigRoundTrip $t)['PathSignatures'] | Should -BeExactly 'C:\USB\signatures-2026'
        (Get-ConfigRoundTrip $t)['PathBelarc']     | Should -BeExactly 'C:\USB'
    }
    It 'satisfies setup.ps1 $RequiredConfig: every required var is non-empty after dot-source' {
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values (New-SampleValues))
        $rt['AdminAccount']    | Should -Not -BeNullOrEmpty
        $rt['AdminNewPass']    | Should -Not -BeNullOrEmpty
        $rt['UserInitialPass'] | Should -Not -BeNullOrEmpty
        @($rt['EmailDomains']).Count | Should -BeGreaterThan 0
        $rt['PathSignatures']  | Should -Not -BeNullOrEmpty
    }
    It 'leaves no unreplaced template placeholder' {
        ConvertTo-ConfigPs1Content -Values (New-SampleValues) | Should -Not -Match '__[A-Z_]+__'
    }
}

Describe 'ConvertTo-ConfigPs1Content — scalar round-trips' {
    It 'preserves credentials byte-for-byte including quote, $ and double-quote' {
        $v  = New-SampleValues
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values $v)
        $rt['AdminAccount']    | Should -BeExactly $v['AdminAccount']
        $rt['AdminNewPass']    | Should -BeExactly $v['AdminNewPass']
        $rt['UserInitialPass'] | Should -BeExactly $v['UserInitialPass']
        $rt['StaticGateway']   | Should -BeExactly $v['StaticGateway']
        $rt['WallpaperFile']   | Should -BeExactly $v['WallpaperFile']
        $rt['WifiSSID']        | Should -BeExactly $v['WifiSSID']
        $rt['WifiPass']        | Should -BeExactly $v['WifiPass']
    }
    It 'keeps StaticPrefixLength an integer' {
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values (New-SampleValues))
        $rt['StaticPrefixLength'] | Should -BeOfType [int]
        $rt['StaticPrefixLength'] | Should -Be 24
    }
}

Describe 'ConvertTo-ConfigPs1Content — array round-trips (PS 5.1 single-element guard)' {
    It 'round-trips a multi-element EmailDomains / DnsServers array' {
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values (New-SampleValues))
        @($rt['EmailDomains']) | Should -Be @('a.example.com', 'b.example.com')
        @($rt['DnsServers'])   | Should -Be @('8.8.8.8', '8.8.4.4')
    }
    It 'keeps a single-element array an array (does not collapse to a scalar)' {
        $v = New-SampleValues; $v['EmailDomains'] = @('only.example.com'); $v['DnsServers'] = @('1.1.1.1')
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values $v)
        # Assert via -is (piping a 1-element array to Should would enumerate it to the scalar).
        ($rt['EmailDomains'] -is [array]) | Should -BeTrue
        @($rt['EmailDomains']).Count | Should -Be 1
        @($rt['DnsServers']).Count   | Should -Be 1
    }
    It 'emits @() for an empty array' {
        $v = New-SampleValues; $v['DnsServers'] = @()
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values $v)
        @($rt['DnsServers']).Count | Should -Be 0
    }
}

Describe 'ConvertTo-ConfigPs1Content — WallpaperByDomain hashtable' {
    It 'round-trips a populated map' {
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values (New-SampleValues))
        $rt['WallpaperByDomain'] | Should -BeOfType [hashtable]
        $rt['WallpaperByDomain']['b.example.com'] | Should -BeExactly 'alt.png'
    }
    It 'emits an empty hashtable for an empty map' {
        $v = New-SampleValues; $v['WallpaperByDomain'] = @{}
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values $v)
        $rt['WallpaperByDomain'] | Should -BeOfType [hashtable]
        $rt['WallpaperByDomain'].Count | Should -Be 0
    }
}

Describe 'ConvertTo-ConfigPs1Content — Bookmarks array-of-hashtables' {
    It 'round-trips name+url, order, and adversarial characters' {
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values (New-SampleValues))
        @($rt['Bookmarks']).Count | Should -Be 2
        $rt['Bookmarks'][0].Name  | Should -BeExactly "O'Brien & Co"
        $rt['Bookmarks'][0].Url   | Should -BeExactly 'https://one.example/'
        $rt['Bookmarks'][1].Url   | Should -BeExactly 'https://two.example/?a=1&b=2'
    }
    It 'keeps a single bookmark an array of one' {
        $v = New-SampleValues; $v['Bookmarks'] = @(@{ Name = 'Solo'; Url = 'https://solo.example/' })
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values $v)
        @($rt['Bookmarks']).Count | Should -Be 1
        $rt['Bookmarks'][0].Name  | Should -BeExactly 'Solo'
    }
    It 'emits @() for no bookmarks' {
        $v = New-SampleValues; $v['Bookmarks'] = @()
        $rt = Get-ConfigRoundTrip (ConvertTo-ConfigPs1Content -Values $v)
        @($rt['Bookmarks']).Count | Should -Be 0
    }
}

Describe 'ConvertTo-ConfigPs1Content — missing optional keys default safely' {
    It 'tolerates a values hashtable that omits every optional key' {
        $t = ConvertTo-ConfigPs1Content -Values @{
            AdminAccount = 'a'; AdminNewPass = 'longenough12'; UserInitialPass = 'longenough12'
            EmailDomains = @('x.example.com')
        }
        { [scriptblock]::Create($t) } | Should -Not -Throw
        $rt = Get-ConfigRoundTrip $t
        @($rt['DnsServers']).Count        | Should -Be 0
        $rt['WallpaperByDomain'].Count    | Should -Be 0
        @($rt['Bookmarks']).Count         | Should -Be 0
        $rt['WifiSSID']                   | Should -BeExactly ''
    }
}

Describe 'Test-Ipv4' {
    It 'accepts a valid dotted-quad' {
        Test-Ipv4 '10.0.0.1' | Should -BeTrue
        Test-Ipv4 '255.255.255.0' | Should -BeTrue
    }
    It 'rejects out-of-range, short, and empty inputs' {
        Test-Ipv4 '10.0.0.256' | Should -BeFalse
        Test-Ipv4 '10.0.1'     | Should -BeFalse
        Test-Ipv4 ''           | Should -BeFalse
    }
}

Describe 'Import-ConfigDefault — reads a generated config.ps1 back as defaults' {
    It 'loads the same values the serializer wrote (whole-file integration)' {
        $v    = New-SampleValues
        $file = Join-Path $TestDrive 'config.ps1'
        [System.IO.File]::WriteAllText($file, (ConvertTo-ConfigPs1Content -Values $v), (New-Object System.Text.UTF8Encoding($true)))

        $d = Import-ConfigDefault -Path $file -ScriptDirValue 'C:\USB'
        $d['AdminAccount']    | Should -BeExactly $v['AdminAccount']
        $d['AdminNewPass']    | Should -BeExactly $v['AdminNewPass']    # secrets load for the "keep" prompt
        @($d['EmailDomains']) | Should -Be @('a.example.com', 'b.example.com')
        $d['WallpaperByDomain']['b.example.com'] | Should -BeExactly 'alt.png'
        @($d['Bookmarks']).Count | Should -Be 2
    }
    It 'returns an empty hashtable when the file does not exist' {
        (Import-ConfigDefault -Path (Join-Path $TestDrive 'nope.ps1')).Count | Should -Be 0
    }
}

Describe 'Get-WallpaperCandidate — auto-detect wallpaper images at the USB root' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ('wp-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    It 'returns only image files, sorted, and ignores non-images' {
        foreach ($f in 'zeta.jpg', 'Alpha.PNG', 'mid.bmp', 'shot.jpeg', 'notes.txt', 'setup.exe') {
            Set-Content -LiteralPath (Join-Path $dir $f) -Value 'x'
        }
        Get-WallpaperCandidate -Directory $dir | Should -Be @('Alpha.PNG', 'mid.bmp', 'shot.jpeg', 'zeta.jpg')
    }
    It 'is non-recursive (ignores images in subfolders)' {
        Set-Content -LiteralPath (Join-Path $dir 'root.png') -Value 'x'
        $sub = Join-Path $dir 'sub'; New-Item -ItemType Directory -Path $sub | Out-Null
        Set-Content -LiteralPath (Join-Path $sub 'nested.png') -Value 'x'
        Get-WallpaperCandidate -Directory $dir | Should -Be @('root.png')
    }
    It 'returns an empty array for an empty folder' {
        @(Get-WallpaperCandidate -Directory $dir).Count | Should -Be 0
    }
    It 'returns an empty array for a missing or empty path' {
        @(Get-WallpaperCandidate -Directory (Join-Path $TestDrive 'does-not-exist')).Count | Should -Be 0
        @(Get-WallpaperCandidate -Directory '').Count | Should -Be 0
    }
}
