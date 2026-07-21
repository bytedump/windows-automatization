#Requires -Version 5.1

# Cross-file contract tests for the Phase A -> Phase B handoff state.
#
# setup.ps1's New-CorpStateObject is the PRODUCER (it builds the object Phase A serializes to
# state.json); phase-b.ps1's Read-CorpState is the CONSUMER. Both files are dot-sourced with
# -LoadOnly (pure functions only - no machine state touched) and exercised against a temp
# state.json, so the producer/consumer contract is proven end-to-end without a VM. No password
# literals here (state carries no credentials) -> gitleaks-clean.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\setup.ps1')  -LoadOnly
    . (Join-Path $PSScriptRoot '..\..\phase-b.ps1') -LoadOnly

    # The exact contract: the 10 fields phase-b.ps1's Read-CorpState reads. No credential field.
    $script:ExpectedFields = @(
        'Username', 'FullName', 'Email', 'EmailDomain',
        'SectorName', 'SigTemplate', 'PrinterName', 'WallpaperPath', 'Bookmarks',
        'DesktopShortcutNames'
    )
    # Scalar (string) fields only - compared byte-for-byte in the round-trip. Bookmarks is an array,
    # so it is asserted separately (element .Name/.Url), not via -BeExactly.
    $script:ScalarFields = @(
        'Username', 'FullName', 'Email', 'EmailDomain',
        'SectorName', 'SigTemplate', 'PrinterName', 'WallpaperPath'
    )
}

Describe 'Test-StateJson - validates state.json before arming AutoLogon (audit A8)' {
    BeforeEach {
        $script:sf = Join-Path $TestDrive 'state.json'
        Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue
    }
    It 'accepts a complete state.json' {
        (New-CorpStateObject -Username 'joao.silva' -FullName 'Joao Silva' -Email 'joao.silva@corp.com') |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sf -Encoding UTF8
        Test-StateJson -Path $sf | Should -BeTrue
    }
    It 'rejects a truncated / non-JSON file (power loss mid-write)' {
        Set-Content -LiteralPath $sf -Value '{ "Username": "joao.silva", "Full' -Encoding UTF8
        Test-StateJson -Path $sf | Should -BeFalse
    }
    It 'rejects valid JSON missing a mandatory field' {
        '{ "FullName": "Joao Silva", "Email": "j@corp.com" }' | Set-Content -LiteralPath $sf -Encoding UTF8
        Test-StateJson -Path $sf | Should -BeFalse
    }
    It 'rejects a missing file' {
        Test-StateJson -Path (Join-Path $TestDrive 'nope.json') | Should -BeFalse
    }
}

Describe 'New-CorpStateObject' {
    It 'exposes exactly the 10 contract fields - and never a credential field' {
        $s = New-CorpStateObject -Username 'joao.silva' -FullName 'Joao Silva' -Email 'joao.silva@corp.com' `
            -EmailDomain 'corp.com' -SectorName 'IT' -SigTemplate 'std.htm' `
            -PrinterName 'HP-IT' -WallpaperPath 'C:\w.jpg' `
            -Bookmarks @(@{ Name = 'Intranet'; Url = 'https://10.0.0.1/portal' }) `
            -DesktopShortcutNames @('Intranet')
        $names = @($s.PSObject.Properties.Name)
        $names | Should -HaveCount 10
        ($names | Sort-Object) | Should -Be ($script:ExpectedFields | Sort-Object)
        # A credential must never leak into state.json.
        ($names | Where-Object { $_ -match '(?i)pass|pwd|cred|secret|token' }) | Should -BeNullOrEmpty
    }

    It 'defaults the optional fields to empty string (and the arrays to empty arrays)' {
        $s = New-CorpStateObject -Username 'a.b' -FullName 'A B' -Email 'a.b@corp.com'
        $s.EmailDomain   | Should -BeExactly ''
        $s.SectorName    | Should -BeExactly ''
        $s.SigTemplate   | Should -BeExactly ''
        $s.PrinterName   | Should -BeExactly ''
        $s.WallpaperPath | Should -BeExactly ''
        @($s.Bookmarks)  | Should -HaveCount 0
        @($s.DesktopShortcutNames) | Should -HaveCount 0
    }

    It 'preserves the Automatic-template sentinel byte-for-byte' {
        # phase-b compares SigTemplate with -eq against this exact string, so it must survive intact.
        $s = New-CorpStateObject -Username 'a.b' -FullName 'A B' -Email 'a.b@corp.com' `
            -SigTemplate '(Automatic - first found)'
        $s.SigTemplate | Should -BeExactly '(Automatic - first found)'
    }

    It 'refuses to build with a blank required field (producer-side defense in depth)' {
        { New-CorpStateObject -Username ''          -FullName 'A B' -Email 'a.b@corp.com' } | Should -Throw
        { New-CorpStateObject -Username 'a.b' -FullName ''    -Email 'a.b@corp.com' } | Should -Throw
        { New-CorpStateObject -Username 'a.b' -FullName 'A B' -Email ''              } | Should -Throw
    }
}

Describe 'state.json round-trip (New-CorpStateObject -> Read-CorpState)' {
    It 'survives serialize/deserialize with every field intact' {
        $s = New-CorpStateObject -Username 'joao.silva' -FullName 'Joao Silva' -Email 'joao.silva@corp.com' `
            -EmailDomain 'corp.com.br' -SectorName 'Sales' -SigTemplate 'sales.htm' `
            -PrinterName 'Epson-Sales' -WallpaperPath 'C:\Windows\Web\Wallpaper\Corp\wallpaper.jpg' `
            -Bookmarks @(
                @{ Name = 'Intranet'; Url = 'https://10.0.0.1/portal' },
                @{ Name = 'WebApp';   Url = 'https://10.0.0.1:1234/webapp/' }
            ) `
            -DesktopShortcutNames @('WebApp')
        $path = Join-Path $TestDrive 'state.json'
        # -Depth 5 mirrors Phase A: the default depth stringifies the Bookmarks objects.
        $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8

        $back = Read-CorpState -Path $path
        foreach ($f in $script:ScalarFields) {
            $back.$f | Should -BeExactly $s.$f
        }
        # Bookmarks come back as PSCustomObject (post-JSON), so assert the values, not object identity.
        @($back.Bookmarks)      | Should -HaveCount 2
        $back.Bookmarks[0].Name | Should -BeExactly 'Intranet'
        $back.Bookmarks[0].Url  | Should -BeExactly 'https://10.0.0.1/portal'
        $back.Bookmarks[1].Name | Should -BeExactly 'WebApp'
        @($back.DesktopShortcutNames) | Should -HaveCount 1
        @($back.DesktopShortcutNames)[0] | Should -BeExactly 'WebApp'
    }

    It 'round-trips ZERO selected bookmarks as a real empty array (not JSON null)' {
        # The exact production path: no box ticked -> @(Select-EnabledBookmarks) -> state -> json
        # -> Read-CorpState. Regression guard: the unwrapped call used to serialize
        # "Bookmarks": null, which failed Set-ChromiumBookmarks's [object[]] binding with a
        # spurious Phase B ERROR. The @() wrap mirrors setup.ps1's $SelectedBookmarks.
        $sel  = @(Select-EnabledBookmarks -Bookmarks @(@{ Name = 'A'; Url = 'https://a.example/' }) -Flags @($false))
        $s    = New-CorpStateObject -Username 'a.b' -FullName 'A B' -Email 'a.b@corp.com' -Bookmarks $sel
        $path = Join-Path $TestDrive 'state-zero.json'
        $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8

        $back = Read-CorpState -Path $path
        ($null -eq $back.Bookmarks)   | Should -BeFalse
        ($back.Bookmarks -is [array]) | Should -BeTrue
        $back.Bookmarks.Count         | Should -Be 0
    }

    It 'reads missing optional fields back as empty string' {
        $s = New-CorpStateObject -Username 'a.b' -FullName 'A B' -Email 'a.b@corp.com'
        $path = Join-Path $TestDrive 'state-min.json'
        $s | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8

        $back = Read-CorpState -Path $path
        $back.Username      | Should -BeExactly 'a.b'
        $back.SectorName    | Should -BeExactly ''
        $back.PrinterName   | Should -BeExactly ''
        $back.WallpaperPath | Should -BeExactly ''
        @($back.DesktopShortcutNames) | Should -HaveCount 0
    }
}

Describe 'Read-CorpState rejects a blank required field' {
    # The consumer is the authoritative gate. Build the state object DIRECTLY (bypassing the
    # builder, which would refuse the blank) so we feed Read-CorpState a malformed state.json
    # exactly as a hand-edited / corrupted file would look.
    It 'throws on a blank <field>' -ForEach @(
        @{ field = 'Username' }, @{ field = 'FullName' }, @{ field = 'Email' }
    ) {
        $obj = [pscustomobject]@{
            Username = 'joao.silva'; FullName = 'Joao Silva'; Email = 'joao.silva@corp.com'
        }
        $obj.$field = ''
        $path = Join-Path $TestDrive "state-bad-$field.json"
        $obj | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8

        { Read-CorpState -Path $path } | Should -Throw "*missing required field: $field*"
    }
}
