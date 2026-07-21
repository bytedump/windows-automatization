#Requires -Version 5.1

# Read-PrinterList parses printers.json into the form's printer list. These cases lock the two
# field-deploy regressions that used to hide below the -LoadOnly seam: the Windows PowerShell 5.1
# top-level-array collapse (the old @(... | ConvertFrom-Json) dropped every printer) and the
# BOM/encoding decode (a UTF-16 / UTF-8-BOM file read via forced -Encoding UTF8 turned to garbage).
# The 5.1 leg of CI is what actually enforces the array-collapse assertion - pwsh 7 never reproduced it.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\setup.ps1') -LoadOnly
}

Describe 'Read-PrinterList' {
    BeforeEach {
        $script:jsonPath = Join-Path $TestDrive 'printers.json'
        Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
        $script:threeJson = '[{"name":"Front Desk","model":"HP LaserJet M404","ip":"10.0.0.11"},{"name":"Finance","model":"HP LaserJet M507","ip":"10.0.0.12"},{"name":"Warehouse","model":"Zebra ZT411","ip":"10.0.0.13"}]'
    }

    It 'parses a top-level JSON array without collapsing it (5.1 regression)' {
        [System.IO.File]::WriteAllText($jsonPath, $threeJson, [System.Text.UTF8Encoding]::new($false))
        $res = Read-PrinterList -Path $jsonPath
        $res.Total             | Should -Be 3
        @($res.Printers).Count | Should -Be 3
        $res.Printers[0].name  | Should -BeExactly 'Front Desk'
    }

    It 'decodes a UTF-8-BOM file (Notepad save) correctly' {
        [System.IO.File]::WriteAllText($jsonPath, $threeJson, [System.Text.UTF8Encoding]::new($true))
        @((Read-PrinterList -Path $jsonPath).Printers).Count | Should -Be 3
    }

    It 'decodes a UTF-16-LE-BOM file (Notepad save) correctly' {
        [System.IO.File]::WriteAllText($jsonPath, $threeJson, [System.Text.Encoding]::Unicode)
        @((Read-PrinterList -Path $jsonPath).Printers).Count | Should -Be 3
    }

    It 'normalizes a lone printer object to a one-element list' {
        $one = '{"name":"Solo","model":"HP","ip":"10.0.0.9"}'
        [System.IO.File]::WriteAllText($jsonPath, $one, [System.Text.UTF8Encoding]::new($false))
        $res = Read-PrinterList -Path $jsonPath
        @($res.Printers).Count | Should -Be 1
        $res.Printers[0].name  | Should -BeExactly 'Solo'
    }

    It 'drops entries missing name/model/ip and reports the count' {
        $mixed = '[{"name":"Good","model":"HP","ip":"10.0.0.1"},{"name":"No IP","model":"HP"},{"model":"HP","ip":"10.0.0.3"}]'
        [System.IO.File]::WriteAllText($jsonPath, $mixed, [System.Text.UTF8Encoding]::new($false))
        $res = Read-PrinterList -Path $jsonPath
        $res.Total                            | Should -Be 3
        @($res.Printers).Count                | Should -Be 1
        ($res.Total - @($res.Printers).Count) | Should -Be 2
    }

    It 'drops an entry with a malformed ip and reports the reason' {
        $bad = '[{"name":"Good","model":"HP","ip":"10.0.0.1"},{"name":"BadIP","model":"HP","ip":"10.0.0.999"},{"name":"CommaIP","model":"HP","ip":"10,0,0,1"}]'
        [System.IO.File]::WriteAllText($jsonPath, $bad, [System.Text.UTF8Encoding]::new($false))
        $res = Read-PrinterList -Path $jsonPath
        @($res.Printers).Count | Should -Be 1
        $res.Printers[0].name  | Should -BeExactly 'Good'
        @($res.Dropped).Count  | Should -Be 2
        ($res.Dropped | Where-Object { $_.name -eq 'BadIP' }).reason   | Should -Match 'invalid ip'
        ($res.Dropped | Where-Object { $_.name -eq 'CommaIP' }).reason | Should -Match 'invalid ip'
    }

    It 'reports missing-field vs invalid-ip drops distinctly' {
        $mix = '[{"name":"Good","model":"HP","ip":"10.0.0.1"},{"name":"NoModel","ip":"10.0.0.2"},{"name":"BadIP","model":"HP","ip":"999.1.1.1"}]'
        [System.IO.File]::WriteAllText($jsonPath, $mix, [System.Text.UTF8Encoding]::new($false))
        $res = Read-PrinterList -Path $jsonPath
        @($res.Printers).Count | Should -Be 1
        ($res.Dropped | Where-Object { $_.name -eq 'NoModel' }).reason | Should -Be 'missing field'
        ($res.Dropped | Where-Object { $_.name -eq 'BadIP' }).reason   | Should -Match 'invalid ip'
    }
}

# The extracted Epson bundle ships several INFs; the printer one is Class=Printer, the helpers
# (port / language monitor) are Class=USB. Resolve-EpsonInf must pick the printer INF, and
# Get-InfPrinterModels must read the model display name registered by that INF.
Describe 'Resolve-EpsonInf' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive 'Drivers Epson'
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    It 'returns $null when the folder does not exist' {
        Resolve-EpsonInf (Join-Path $TestDrive 'nope') | Should -BeNullOrEmpty
    }

    It 'returns $null when there is no .inf' {
        Set-Content -LiteralPath (Join-Path $dir 'readme.txt') -Value 'x' -Encoding UTF8
        Resolve-EpsonInf $dir | Should -BeNullOrEmpty
    }

    It 'prefers a Class=Printer INF over a Class=USB one' {
        Set-Content -LiteralPath (Join-Path $dir 'AAA_util.inf')   -Value "[Version]`r`nClass=USB"     -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'ZZZ_print.inf')  -Value "[Version]`r`nClass=Printer" -Encoding UTF8
        (Resolve-EpsonInf $dir) | Should -Match 'ZZZ_print\.inf$'
    }

    It 'falls back to the first .inf when none declares Class=Printer' {
        Set-Content -LiteralPath (Join-Path $dir 'a.inf') -Value "[Version]`r`nClass=USB" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'b.inf') -Value "[Version]`r`nClass=USB" -Encoding UTF8
        (Resolve-EpsonInf $dir) | Should -Match 'a\.inf$'
    }
}

Describe 'Get-InfPrinterModels' {
    It 'reads the model display name from a printer INF' {
        $inf = Join-Path $TestDrive 'printer.inf'
        Set-Content -LiteralPath $inf -Encoding UTF8 -Value @'
[Version]
Class=Printer
[Manufacturer]
%EPSON% = EPSON,NTamd64
[EPSON]
"EPSON WF-M5899 Series" = EPNDRV_Mdl_01,USBPRINT\EPSONWF-M5899
[Strings]
EPSON = "EPSON"
'@
        $m = @(Get-InfPrinterModels -InfPath $inf)
        $m | Should -Contain 'EPSON WF-M5899 Series'
        $m.Count | Should -Be 1
    }

    It 'returns an empty array when there is no [Manufacturer] section' {
        $inf = Join-Path $TestDrive 'nomfg.inf'
        Set-Content -LiteralPath $inf -Value "[Version]`r`nClass=Printer" -Encoding UTF8
        @(Get-InfPrinterModels -InfPath $inf).Count | Should -Be 0
    }
}
