#Requires -Version 5.1

# Unit tests for New-WlanProfileXml (pure WLAN profile XML builder in setup.ps1).
# setup.ps1 is dot-sourced with -LoadOnly, which defines the functions and returns
# before the provisioning body runs - so these tests touch no machine state.
# Connect-CorpWifi is intentionally NOT unit-tested: it lives below the -LoadOnly seam
# and drives netsh/services/CIM with real sleeps (same policy as Test-InternetUp).

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\setup.ps1') -LoadOnly
}

Describe 'New-WlanProfileXml' {
    Context 'WPA2PSK variant (default)' {
        BeforeAll {
            $script:raw = New-WlanProfileXml -Ssid 'TestCorp-WiFi' -Passphrase 'FakeWifiPass123'
            $script:xml = [xml]$script:raw
        }

        It 'parses as valid XML' { $xml | Should -Not -BeNullOrEmpty }
        It 'uses WPA2PSK authentication' {
            $xml.WLANProfile.MSM.security.authEncryption.authentication | Should -Be 'WPA2PSK'
        }
        It 'has no transitionMode element' { $raw | Should -Not -Match 'transitionMode' }
        It 'requests auto-connect' { $xml.WLANProfile.connectionMode | Should -Be 'auto' }
        It 'profile name and SSID both equal the input' {
            $xml.WLANProfile.name | Should -Be 'TestCorp-WiFi'
            $xml.WLANProfile.SSIDConfig.SSID.name | Should -Be 'TestCorp-WiFi'
        }
        It 'carries the passphrase as keyMaterial' {
            $xml.WLANProfile.MSM.security.sharedKey.keyMaterial | Should -Be 'FakeWifiPass123'
        }
    }

    Context 'WPA3SAE variant' {
        BeforeAll {
            $script:xml = [xml](New-WlanProfileXml -Ssid 'CorpNet' -Passphrase 'p@ssw0rd!' -Authentication 'WPA3SAE')
            $script:authEnc = $script:xml.WLANProfile.MSM.security.authEncryption
        }

        It 'uses WPA3SAE authentication' { $authEnc.authentication | Should -Be 'WPA3SAE' }
        It 'has transitionMode=true in the v4 namespace' {
            $node = $authEnc.ChildNodes | Where-Object { $_.LocalName -eq 'transitionMode' }
            $node | Should -Not -BeNullOrEmpty
            $node.InnerText | Should -Be 'true'
            $node.NamespaceURI | Should -Be 'http://www.microsoft.com/networking/WLAN/profile/v4'
        }
        It 'places transitionMode after useOneX inside authEncryption' {
            $names = @($authEnc.ChildNodes | ForEach-Object { $_.LocalName })
            $names.IndexOf('transitionMode') | Should -BeGreaterThan $names.IndexOf('useOneX')
        }
    }

    Context 'XML escaping' {
        It 'round-trips SSID and passphrase containing XML-special characters' {
            $ssid = 'Bar & "Grill" <5>'
            $pass = "o'brien<&>987"
            $xml = [xml](New-WlanProfileXml -Ssid $ssid -Passphrase $pass)
            $xml.WLANProfile.name | Should -Be $ssid
            $xml.WLANProfile.SSIDConfig.SSID.name | Should -Be $ssid
            $xml.WLANProfile.MSM.security.sharedKey.keyMaterial | Should -Be $pass
        }
    }
}
