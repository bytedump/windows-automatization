#Requires -Version 5.1

# Unit tests for the pure input validators/normalizers in setup.ps1.
# setup.ps1 is dot-sourced with -LoadOnly, which defines the functions and returns
# before the provisioning body runs - so these tests touch no machine state.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\setup.ps1') -LoadOnly
}

Describe 'Test-Ipv4' {
    It 'accepts valid IPv4 <ip>' -ForEach @(
        @{ ip = '10.0.1.50' }
        @{ ip = '0.0.0.0' }
        @{ ip = '255.255.255.255' }
        @{ ip = ' 192.168.1.1 ' }   # trimmed
    ) { Test-Ipv4 $ip | Should -BeTrue }

    It 'rejects invalid IPv4 <ip>' -ForEach @(
        @{ ip = '10.0.1' }          # too few octets
        @{ ip = '1.2.3.4.5' }       # too many octets
        @{ ip = '10.0.0.999' }      # octet > 255
        @{ ip = '256.1.1.1' }       # octet > 255
        @{ ip = '10,0,0,5' }        # wrong separator
        @{ ip = 'abc' }
        @{ ip = '' }
        @{ ip = $null }
    ) { Test-Ipv4 $ip | Should -BeFalse }
}

Describe 'Test-Username' {
    It 'accepts firstname.surname' { Test-Username 'joao.silva' | Should -BeTrue }

    It 'rejects invalid username <u>' -ForEach @(
        @{ u = 'joao' }              # no dot
        @{ u = 'joao.silva.santos' } # two dots
        @{ u = 'Joao.Silva' }        # uppercase (case-sensitive match)
        @{ u = 'joao silva' }        # space
        @{ u = 'joao.silva1' }       # digit
        @{ u = '.silva' }            # empty first
        @{ u = 'joao.' }             # empty surname
        @{ u = '' }
    ) { Test-Username $u | Should -BeFalse }
}

Describe 'Remove-Diacritics' {
    It 'strips Portuguese accents and cedilla' {
        Remove-Diacritics 'José da Conceição' | Should -BeExactly 'Jose da Conceicao'
    }
    It 'returns empty for empty input' { Remove-Diacritics '' | Should -BeExactly '' }
}

Describe 'Format-FullName' {
    It 'title-cases and lowercases Portuguese particles' {
        Format-FullName 'joao da silva' | Should -BeExactly 'Joao da Silva'
    }
    It 'strips digits and symbols' {
        Format-FullName 'joao123 silva!' | Should -BeExactly 'Joao Silva'
    }
    It 'returns empty when there are no letters' {
        Format-FullName '123 456' | Should -BeExactly ''
    }
}

Describe 'Format-Username' {
    It 'builds firstname.surname, lowercased' {
        Format-Username 'Joao Pedro' 'da Silva' | Should -BeExactly 'joao.silva'
    }
    It 'strips accents before building' {
        Format-Username 'João' 'Conceição' | Should -BeExactly 'joao.conceicao'
    }
    It 'returns empty when a name part is missing' {
        Format-Username 'Joao' '' | Should -BeExactly ''
    }
}
