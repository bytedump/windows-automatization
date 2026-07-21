#Requires -Version 5.1

# Unit tests for the pure helpers in phase-b.ps1 (signature template resolution,
# signature rewrite, state.json parsing/normalization). phase-b.ps1 is dot-sourced
# with -LoadOnly so only the functions load - no machine state (HKCU, profile,
# printers) is touched. The side-effecting steps are validated on a VM, not here.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\phase-b.ps1') -LoadOnly
}

Describe 'Convert-SignatureContent' {
    It 'replaces both the bold name and the first email' {
        $html = '<p><span style="font-weight: bold">Old Name</span><br>old.name@corp.com</p>'
        $r = Convert-SignatureContent -Content $html -NewName 'New Person' -NewEmail 'new.person@corp.com'
        $r.OldName  | Should -BeExactly 'Old Name'
        $r.OldEmail | Should -BeExactly 'old.name@corp.com'
        $r.Content  | Should -Match 'New Person'
        $r.Content  | Should -Match 'new\.person@corp\.com'
        $r.Content  | Should -Not -Match 'Old Name'
        $r.Content  | Should -Not -Match 'old\.name@corp\.com'
    }

    It 'reports empty old values and leaves content unchanged when nothing matches' {
        $html = '<p>no markers here</p>'
        $r = Convert-SignatureContent -Content $html -NewName 'New Person' -NewEmail 'new.person@corp.com'
        $r.OldName  | Should -BeExactly ''
        $r.OldEmail | Should -BeExactly ''
        $r.Content  | Should -BeExactly $html
    }

    It 'swaps the email even when there is no bold name' {
        $html = '<p>contact: old@corp.com</p>'
        $r = Convert-SignatureContent -Content $html -NewName 'Whoever' -NewEmail 'new@corp.com'
        $r.OldEmail | Should -BeExactly 'old@corp.com'
        $r.OldName  | Should -BeExactly ''
        $r.Content  | Should -BeExactly '<p>contact: new@corp.com</p>'
    }

    It 'trims surrounding whitespace from the detected name' {
        $html = '<span style="font-weight:bold">  Spaced Name  </span>'
        $r = Convert-SignatureContent -Content $html -NewName 'Tight' -NewEmail 'x@y.zz'
        $r.OldName | Should -BeExactly 'Spaced Name'
    }

    It 'accepts an empty content string' {
        $r = Convert-SignatureContent -Content '' -NewName 'A' -NewEmail 'a@b.cc'
        $r.Content  | Should -BeExactly ''
        $r.OldName  | Should -BeExactly ''
        $r.OldEmail | Should -BeExactly ''
    }

    It 'inserts replacement values literally even when they contain $ metacharacters' {
        $html = '<span style="font-weight:bold">Old</span> old@corp.com'
        $r = Convert-SignatureContent -Content $html -NewName 'A$&B' -NewEmail 'x$1@corp.com'
        $r.Content | Should -Match ([regex]::Escape('A$&B'))
        $r.Content | Should -Match ([regex]::Escape('x$1@corp.com'))
    }
}

Describe 'Update-SignatureAssetRefs' {
    It 'repoints the asset-folder token to the new base (covers src= and v:imagedata)' {
        $html = '<img src="Sales_files/image001.png"><v:imagedata src="Sales_files/image002.png">'
        $r = Update-SignatureAssetRefs -Content $html -OldBase 'Sales' -NewBase 'joao.silva'
        $r | Should -Match ([regex]::Escape('joao.silva_files/image001.png'))
        $r | Should -Match ([regex]::Escape('joao.silva_files/image002.png'))
        $r | Should -Not -Match 'Sales_files'
    }

    It 'handles single-quoted references' {
        $html = "<img src='Sales_files/a.png'>"
        Update-SignatureAssetRefs -Content $html -OldBase 'Sales' -NewBase 'joao' |
            Should -Match ([regex]::Escape('joao_files/a.png'))
    }

    It 'is a no-op when old and new base are equal' {
        $html = '<img src="x_files/a.png">'
        Update-SignatureAssetRefs -Content $html -OldBase 'x' -NewBase 'x' | Should -BeExactly $html
    }

    It 'leaves content without asset references unchanged' {
        $html = '<p>no images</p>'
        Update-SignatureAssetRefs -Content $html -OldBase 'Sales' -NewBase 'joao' | Should -BeExactly $html
    }
}

Describe 'Resolve-SignatureTemplate' {
    BeforeEach {
        # TestDrive persists across Its - wipe the tree so each case starts clean.
        $script:root   = Join-Path $TestDrive 'Signatures'
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        $script:sector = Join-Path $root 'corp.com\Sales'
        New-Item -ItemType Directory -Path $sector -Force | Out-Null
    }

    It 'picks the first .htm, skipping dot/underscore side-car files (Automatic mode)' {
        Set-Content -LiteralPath (Join-Path $sector '_hidden.htm') -Value 'x' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $sector 'real.htm')    -Value 'x' -Encoding UTF8
        $f = Resolve-SignatureTemplate -SignaturesRoot $root -EmailDomain 'corp.com' `
            -SectorName 'Sales' -SigTemplate '(Automatic - first found)'
        $f.Name | Should -BeExactly 'real.htm'
    }

    It 'returns the named template when given an explicit name' {
        Set-Content -LiteralPath (Join-Path $sector 'a.htm') -Value 'x' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $sector 'b.htm') -Value 'x' -Encoding UTF8
        $f = Resolve-SignatureTemplate -SignaturesRoot $root -EmailDomain 'corp.com' `
            -SectorName 'Sales' -SigTemplate 'b.htm'
        $f.Name | Should -BeExactly 'b.htm'
    }

    It 'returns $null when the sector folder does not exist' {
        $f = Resolve-SignatureTemplate -SignaturesRoot $root -EmailDomain 'corp.com' `
            -SectorName 'Nope' -SigTemplate '(Automatic - first found)'
        $f | Should -BeNullOrEmpty
    }

    It 'returns $null when the named template is missing' {
        $f = Resolve-SignatureTemplate -SignaturesRoot $root -EmailDomain 'corp.com' `
            -SectorName 'Sales' -SigTemplate 'ghost.htm'
        $f | Should -BeNullOrEmpty
    }

    It 'returns $null in Automatic mode when only side-car files exist' {
        Set-Content -LiteralPath (Join-Path $sector '.dotfile.htm') -Value 'x' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $sector '_under.htm')   -Value 'x' -Encoding UTF8
        $f = Resolve-SignatureTemplate -SignaturesRoot $root -EmailDomain 'corp.com' `
            -SectorName 'Sales' -SigTemplate '(Automatic - first found)'
        $f | Should -BeNullOrEmpty
    }
}

Describe 'Read-CorpState' {
    BeforeEach {
        $script:stateFile = Join-Path $TestDrive 'state.json'
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    }

    It 'parses a full state file' {
        @{
            Username = 'joao.silva'; FullName = 'Joao Silva'; Email = 'joao.silva@corp.com'
            EmailDomain = 'corp.com'; SectorName = 'Sales'; SigTemplate = '(Automatic - first found)'
            PrinterName = 'Sales-PB'; WallpaperPath = 'C:\wp.jpg'
        } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $s = Read-CorpState -Path $stateFile
        $s.Username      | Should -BeExactly 'joao.silva'
        $s.FullName      | Should -BeExactly 'Joao Silva'
        $s.Email         | Should -BeExactly 'joao.silva@corp.com'
        $s.PrinterName   | Should -BeExactly 'Sales-PB'
        $s.WallpaperPath | Should -BeExactly 'C:\wp.jpg'
    }

    It 'normalizes missing optional fields to empty strings (StrictMode-safe)' {
        @{ Username = 'a.b'; FullName = 'A B'; Email = 'a.b@corp.com' } |
            ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $s = Read-CorpState -Path $stateFile
        $s.SectorName    | Should -BeExactly ''
        $s.SigTemplate   | Should -BeExactly ''
        $s.PrinterName   | Should -BeExactly ''
        $s.WallpaperPath | Should -BeExactly ''
        # Bookmarks is the one optional that defaults to an array, not '' (downstream iterates it).
        # Assert the value itself, not @(...) of it: the @() wrap let a $null pass this test.
        ($null -eq $s.Bookmarks)   | Should -BeFalse
        ($s.Bookmarks -is [array]) | Should -BeTrue
        $s.Bookmarks.Count         | Should -Be 0
    }

    It 'normalizes a JSON null Bookmarks to a real empty array (zero-selection state.json)' {
        @{
            Username = 'a.b'; FullName = 'A B'; Email = 'a.b@corp.com'
            Bookmarks = $null
        } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $s = Read-CorpState -Path $stateFile
        ($null -eq $s.Bookmarks)   | Should -BeFalse
        ($s.Bookmarks -is [array]) | Should -BeTrue
        $s.Bookmarks.Count         | Should -Be 0
    }

    It 'parses a bookmarks array when present' {
        @{
            Username = 'a.b'; FullName = 'A B'; Email = 'a.b@corp.com'
            Bookmarks = @(
                @{ Name = 'Intranet'; Url = 'https://10.0.0.1/portal' },
                @{ Name = 'WebApp';   Url = 'https://10.0.0.1:1234/webapp/' }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $s = Read-CorpState -Path $stateFile
        @($s.Bookmarks)      | Should -HaveCount 2
        $s.Bookmarks[0].Name | Should -BeExactly 'Intranet'
        $s.Bookmarks[1].Url  | Should -BeExactly 'https://10.0.0.1:1234/webapp/'
    }

    It 'throws when the file does not exist' {
        { Read-CorpState -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
    }

    It 'throws on invalid JSON' {
        Set-Content -LiteralPath $stateFile -Value '{ not json ' -Encoding UTF8
        { Read-CorpState -Path $stateFile } | Should -Throw '*not valid JSON*'
    }

    It 'throws when a required field is missing' {
        @{ Username = 'a.b'; FullName = 'A B' } |   # no Email
            ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        { Read-CorpState -Path $stateFile } | Should -Throw '*missing required field: Email*'
    }

    It 'throws when a required field is blank' {
        @{ Username = 'a.b'; FullName = '   '; Email = 'a.b@corp.com' } |
            ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        { Read-CorpState -Path $stateFile } | Should -Throw '*missing required field: FullName*'
    }
}

# Install-UserSignature is a side-effecting step, but its file pipeline (resolve template ->
# rewrite name/email -> copy the <base>_files assets -> repoint refs -> write into the user's
# %APPDATA%) is the glue the pure-function tests above do not cover end-to-end. We exercise it
# with $env:APPDATA redirected to TestDrive and Set-DefaultSignature mocked, so no real registry
# (HKCU/HKLM) is touched - only the user-profile file writes, which are the point of the test.
Describe 'Install-UserSignature (file pipeline)' {
    BeforeAll { $script:origAppData = $env:APPDATA }
    AfterAll  { $env:APPDATA = $script:origAppData }

    BeforeEach {
        # Redirect the user profile so the signature lands under TestDrive, not the real %APPDATA%.
        # TestDrive persists across Its - wipe it so each case starts with no signature folder.
        $script:appData = Join-Path $TestDrive 'AppData\Roaming'
        Remove-Item -LiteralPath $appData -Recurse -Force -ErrorAction SilentlyContinue
        $env:APPDATA = $appData
        $script:sigOut = Join-Path $appData 'Microsoft\Signatures'

        # Staged signature tree (what Phase A copies): <root>\<domain>\<sector>\<template>.htm
        # plus the sibling <template>_files asset folder.
        $script:root   = Join-Path $TestDrive 'Signatures'
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        $script:sector = Join-Path $root 'corp.com\Sales'
        New-Item -ItemType Directory -Path $sector -Force | Out-Null

        # Default-signature registration is out of scope here (it mutates HKCU/HKLM).
        Mock -CommandName Set-DefaultSignature -MockWith { }
    }

    It 'writes the rewritten .htm into %APPDATA% and copies + repoints the _files assets' {
        Set-Content -LiteralPath (Join-Path $sector 'team.htm') -Encoding UTF8 -Value @'
<p><span style="font-weight: bold">Old Name</span><br>old.name@corp.com</p>
<img src="team_files/logo.png">
'@
        $assets = Join-Path $sector 'team_files'
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $assets 'logo.png') -Value 'PNGDATA' -Encoding UTF8

        $state = [pscustomobject]@{
            Username = 'joao.silva'; FullName = 'Joao Silva'; Email = 'joao.silva@corp.com'
            EmailDomain = 'corp.com'; SectorName = 'Sales'; SigTemplate = '(Automatic - first found)'
            PrinterName = ''; WallpaperPath = ''
        }

        Install-UserSignature -State $state -SignaturesRoot $root

        $htm = Join-Path $sigOut 'joao.silva.htm'
        Test-Path -LiteralPath $htm | Should -BeTrue
        $written = Get-Content -LiteralPath $htm -Raw
        $written | Should -Match 'Joao Silva'
        $written | Should -Match 'joao\.silva@corp\.com'
        $written | Should -Not -Match 'Old Name'
        $written | Should -Not -Match 'old\.name@corp\.com'

        # Assets copied to <Username>_files and the reference repointed away from <template>_files.
        Test-Path -LiteralPath (Join-Path $sigOut 'joao.silva_files\logo.png') | Should -BeTrue
        $written | Should -Match ([regex]::Escape('joao.silva_files/logo.png'))
        $written | Should -Not -Match 'team_files'

        # The .txt (plain-text) and .rtf (RTF) companions are derived from the rendered .htm.
        $txt = Join-Path $sigOut 'joao.silva.txt'
        $rtf = Join-Path $sigOut 'joao.silva.rtf'
        Test-Path -LiteralPath $txt | Should -BeTrue
        Test-Path -LiteralPath $rtf | Should -BeTrue
        $plain = Get-Content -LiteralPath $txt -Raw
        $plain | Should -Match 'Joao Silva'
        $plain | Should -Not -Match 'Old Name'
        $plain | Should -Not -Match '<'          # tags stripped, no HTML leaked into the .txt
        (Get-Content -LiteralPath $rtf -Raw) | Should -Match '^\{\\rtf1'

        Should -Invoke -CommandName Set-DefaultSignature -Times 1 -Exactly
    }

    It 'skips (no file, no throw) when the sector is the no-signature sentinel' {
        $state = [pscustomobject]@{
            Username = 'joao.silva'; FullName = 'Joao Silva'; Email = 'joao.silva@corp.com'
            EmailDomain = 'corp.com'; SectorName = '(Nenhum)'; SigTemplate = ''
            PrinterName = ''; WallpaperPath = ''
        }
        { Install-UserSignature -State $state -SignaturesRoot $root } | Should -Not -Throw
        Test-Path -LiteralPath $sigOut | Should -BeFalse
        Should -Invoke -CommandName Set-DefaultSignature -Times 0 -Exactly
    }

    It 'warns (no file, no throw) when no template exists under the sector' {
        $state = [pscustomobject]@{
            Username = 'joao.silva'; FullName = 'Joao Silva'; Email = 'joao.silva@corp.com'
            EmailDomain = 'corp.com'; SectorName = 'Sales'; SigTemplate = '(Automatic - first found)'
            PrinterName = ''; WallpaperPath = ''
        }
        { Install-UserSignature -State $state -SignaturesRoot $root } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $sigOut 'joao.silva.htm') | Should -BeFalse
        Should -Invoke -CommandName Set-DefaultSignature -Times 0 -Exactly
    }
}

# Install-UserVpnProfile is side-effecting, but its core (find the staged .ovpn -> copy it into the
# user's OpenVPN config dir, or skip cleanly when VPN was not selected) is worth covering. -ConfigDir
# points at TestDrive and -GuiPath at a path that does NOT exist, so the OpenVPN-GUI autostart/launch
# branch (HKCU + Start-Process) never fires - only the profile copy, which is the point of the test.
Describe 'Install-UserVpnProfile (profile import)' {
    BeforeEach {
        $script:staging = Join-Path $TestDrive 'VPN'
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        $script:cfgDir  = Join-Path $TestDrive 'UserProfile\OpenVPN\config'
        Remove-Item -LiteralPath $cfgDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:noGui   = Join-Path $TestDrive 'nope\openvpn-gui.exe'
    }

    It 'imports the staged .ovpn into the user config dir' {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staging 'Servidor-OpenVPN.ovpn') -Value 'client' -Encoding UTF8

        Install-UserVpnProfile -StagingRoot $staging -ConfigDir $cfgDir -GuiPath $noGui

        Test-Path -LiteralPath (Join-Path $cfgDir 'Servidor-OpenVPN.ovpn') | Should -BeTrue
    }

    It 'skips (no throw, no copy) when nothing was staged (VPN not selected)' {
        { Install-UserVpnProfile -StagingRoot $staging -ConfigDir $cfgDir -GuiPath $noGui } | Should -Not -Throw
        Test-Path -LiteralPath $cfgDir | Should -BeFalse
    }

    It 'skips (no throw) when the staging folder exists but holds no .ovpn' {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staging 'readme.txt') -Value 'x' -Encoding UTF8
        { Install-UserVpnProfile -StagingRoot $staging -ConfigDir $cfgDir -GuiPath $noGui } | Should -Not -Throw
        Test-Path -LiteralPath $cfgDir | Should -BeFalse
    }
}

# Set-UserDefaultPrinter is side-effecting (CIM + HKCU), so every cmdlet it calls is mocked. This
# covers the two hardened behaviors: SetDefaultPrinter's ReturnValue is honored (a non-zero result
# logs WARN, not OK), and a name containing [ ] wildcards is matched exactly (the old Get-Printer
# -Name guard treated brackets as a wildcard class and skipped the default silently).
Describe 'Set-UserDefaultPrinter' {
    BeforeAll {
        # Invoke-CimMethod -InputObject is typed [CimInstance], so a PSCustomObject stand-in fails
        # parameter binding before the mock even runs. Build a real (empty) Win32_Printer CimInstance
        # carrying just the Name property the function reads.
        function New-FakePrinter([string]$Name) {
            $ci = [Microsoft.Management.Infrastructure.CimInstance]::new('Win32_Printer', 'root/cimv2')
            $ci.CimInstanceProperties.Add([Microsoft.Management.Infrastructure.CimProperty]::Create(
                'Name', $Name, [Microsoft.Management.Infrastructure.CimType]::String,
                [Microsoft.Management.Infrastructure.CimFlags]::Property))
            $ci
        }
    }
    BeforeEach {
        Mock -CommandName Set-ItemProperty -MockWith { }   # no real HKCU write
        Mock -CommandName Write-PhaseLog   -MockWith { }   # capture Level/Message for assertions
    }

    It 'logs OK when SetDefaultPrinter returns 0' {
        Mock -CommandName Get-CimInstance  -MockWith { New-FakePrinter 'Sala_17' }
        Mock -CommandName Invoke-CimMethod -MockWith { [pscustomobject]@{ ReturnValue = 0 } }

        Set-UserDefaultPrinter -PrinterName 'Sala_17'

        Should -Invoke -CommandName Write-PhaseLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'OK' -and $Message -match 'Default printer set'
        }
    }

    It 'logs WARN (not OK) when SetDefaultPrinter returns non-zero' {
        Mock -CommandName Get-CimInstance  -MockWith { New-FakePrinter 'Sala_17' }
        Mock -CommandName Invoke-CimMethod -MockWith { [pscustomobject]@{ ReturnValue = 5 } }

        Set-UserDefaultPrinter -PrinterName 'Sala_17'

        Should -Invoke -CommandName Write-PhaseLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'ReturnValue=5'
        }
        Should -Invoke -CommandName Write-PhaseLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'OK' }
    }

    It 'sets a printer whose name contains [ ] (regression for the -Name wildcard guard)' {
        Mock -CommandName Get-CimInstance  -MockWith { New-FakePrinter 'HP [Recepcao]' }
        Mock -CommandName Invoke-CimMethod -MockWith { [pscustomobject]@{ ReturnValue = 0 } }

        Set-UserDefaultPrinter -PrinterName 'HP [Recepcao]'

        Should -Invoke -CommandName Invoke-CimMethod -Times 1 -Exactly
        Should -Invoke -CommandName Write-PhaseLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'OK' -and $Message -match 'Default printer set'
        }
    }

    It 'warns and never calls SetDefaultPrinter when the printer is absent' {
        Mock -CommandName Get-CimInstance  -MockWith { }   # nothing enumerated
        Mock -CommandName Invoke-CimMethod -MockWith { [pscustomobject]@{ ReturnValue = 0 } }

        Set-UserDefaultPrinter -PrinterName 'Ghost'

        Should -Invoke -CommandName Invoke-CimMethod -Times 0 -Exactly
        Should -Invoke -CommandName Write-PhaseLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'not found'
        }
    }

    It 'skips with INFO (no CIM lookup) when no printer name is in state' {
        Mock -CommandName Get-CimInstance -MockWith { [pscustomobject]@{ Name = 'x' } }

        Set-UserDefaultPrinter -PrinterName ''

        Should -Invoke -CommandName Get-CimInstance -Times 0 -Exactly
        Should -Invoke -CommandName Write-PhaseLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' }
    }
}

# Set-BookmarkDesktopShortcut writes plain .url files, so -DesktopPath is pointed at TestDrive and
# the real desktop is never touched. Covers the scheme prefix (config stores the bare host), the
# name-list coupling (only configured + selected bookmarks get a shortcut) and the no-clobber guard.
Describe 'Set-BookmarkDesktopShortcut' {
    BeforeEach {
        $script:desk = Join-Path $TestDrive 'Desktop'
        Remove-Item -LiteralPath $desk -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $desk -Force | Out-Null
        $script:lnk = Join-Path $desk 'WebApp.url'
    }

    It 'creates a .url only for configured names and prefixes http:// on a bare host' {
        $bm = @(
            @{ Name = 'Intranet'; Url = '10.0.0.1' },
            @{ Name = 'WebApp'; Url = '10.0.0.127' }
        )
        Set-BookmarkDesktopShortcut -Bookmarks $bm -Names @('WebApp') -DesktopPath $desk

        Test-Path -LiteralPath $lnk | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $desk 'Intranet.url') | Should -BeFalse
        $content = Get-Content -LiteralPath $lnk -Raw
        $content | Should -Match '\[InternetShortcut\]'
        $content | Should -Match ([regex]::Escape('URL=http://10.0.0.127'))
    }

    It 'creates one shortcut per configured name' {
        $bm = @(
            @{ Name = 'Intranet'; Url = '10.0.0.1' },
            @{ Name = 'WebApp'; Url = '10.0.0.127' }
        )
        Set-BookmarkDesktopShortcut -Bookmarks $bm -Names @('Intranet', 'WebApp') -DesktopPath $desk

        Test-Path -LiteralPath (Join-Path $desk 'Intranet.url') | Should -BeTrue
        Test-Path -LiteralPath $lnk | Should -BeTrue
    }

    It 'keeps an explicit scheme untouched' {
        Set-BookmarkDesktopShortcut -DesktopPath $desk -Names @('WebApp') `
            -Bookmarks @(@{ Name = 'WebApp'; Url = 'https://10.0.0.1:1234/webapp/' })

        (Get-Content -LiteralPath $lnk -Raw) |
            Should -Match ([regex]::Escape('URL=https://10.0.0.1:1234/webapp/'))
        (Get-Content -LiteralPath $lnk -Raw) | Should -Not -Match 'http://https'
    }

    It 'skips (no file, no throw) when no configured bookmark was selected' {
        { Set-BookmarkDesktopShortcut -DesktopPath $desk -Names @('WebApp') `
            -Bookmarks @(@{ Name = 'Intranet'; Url = '10.0.0.1' }) } | Should -Not -Throw
        Test-Path -LiteralPath $lnk | Should -BeFalse
    }

    It 'skips (no file, no throw) on an empty selection' {
        { Set-BookmarkDesktopShortcut -DesktopPath $desk -Names @('WebApp') -Bookmarks @() } | Should -Not -Throw
        Test-Path -LiteralPath $lnk | Should -BeFalse
    }

    It 'skips everything when no names are configured' {
        { Set-BookmarkDesktopShortcut -DesktopPath $desk -Names @() `
            -Bookmarks @(@{ Name = 'WebApp'; Url = '10.0.0.127' }) } | Should -Not -Throw
        Test-Path -LiteralPath $lnk | Should -BeFalse
    }

    It 'never clobbers an existing shortcut' {
        Set-Content -LiteralPath $lnk -Value 'user edited this' -Encoding ASCII
        Set-BookmarkDesktopShortcut -DesktopPath $desk -Names @('WebApp') `
            -Bookmarks @(@{ Name = 'WebApp'; Url = '10.0.0.127' })

        (Get-Content -LiteralPath $lnk -Raw) | Should -Match 'user edited this'
    }

    It 'ignores a configured entry with a blank Url (null elements are stripped by Read-CorpState)' {
        { Set-BookmarkDesktopShortcut -DesktopPath $desk -Names @('WebApp') `
            -Bookmarks @(@{ Name = 'WebApp'; Url = '' }) } | Should -Not -Throw
        Test-Path -LiteralPath $lnk | Should -BeFalse
    }
}
