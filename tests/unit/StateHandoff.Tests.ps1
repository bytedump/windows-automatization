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

    # The exact contract: the 8 fields phase-b.ps1's Read-CorpState reads. No credential field.
    $script:ExpectedFields = @(
        'Username', 'FullName', 'Email', 'EmailDomain',
        'SectorName', 'SigTemplate', 'PrinterName', 'WallpaperPath'
    )
}

Describe 'New-CorpStateObject' {
    It 'exposes exactly the 8 contract fields - and never a credential field' {
        $s = New-CorpStateObject -Username 'joao.silva' -FullName 'Joao Silva' -Email 'joao.silva@corp.com' `
            -EmailDomain 'corp.com' -SectorName 'TI' -SigTemplate 'std.htm' `
            -PrinterName 'HP-TI' -WallpaperPath 'C:\w.jpg'
        $names = @($s.PSObject.Properties.Name)
        $names | Should -HaveCount 8
        ($names | Sort-Object) | Should -Be ($script:ExpectedFields | Sort-Object)
        # A credential must never leak into state.json.
        ($names | Where-Object { $_ -match '(?i)pass|pwd|cred|secret|token' }) | Should -BeNullOrEmpty
    }

    It 'defaults the optional fields to empty string' {
        $s = New-CorpStateObject -Username 'a.b' -FullName 'A B' -Email 'a.b@corp.com'
        $s.EmailDomain   | Should -BeExactly ''
        $s.SectorName    | Should -BeExactly ''
        $s.SigTemplate   | Should -BeExactly ''
        $s.PrinterName   | Should -BeExactly ''
        $s.WallpaperPath | Should -BeExactly ''
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
            -EmailDomain 'corp.com.br' -SectorName 'Vendas' -SigTemplate 'vendas.htm' `
            -PrinterName 'Epson-Vendas' -WallpaperPath 'C:\Windows\Web\Wallpaper\Corp\wallpaper.jpg'
        $path = Join-Path $TestDrive 'state.json'
        $s | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8

        $back = Read-CorpState -Path $path
        foreach ($f in $script:ExpectedFields) {
            $back.$f | Should -BeExactly $s.$f
        }
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
