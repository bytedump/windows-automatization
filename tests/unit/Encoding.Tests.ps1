# Repo encoding hygiene. Windows PowerShell 5.1 (the production runtime) reads a BOM-less .ps1 as
# the ANSI code page, NOT UTF-8, so any non-ASCII byte (em-dash, accented literal) is mis-decoded
# and the file mis-parses or mis-reads. Every .ps1 that contains non-ASCII MUST therefore start
# with a UTF-8 BOM. This guards the whole class of bug (the wizard crash, the accent-test failures)
# against a BOM-stripping edit that CI under pwsh 7 would otherwise pass green.
#
# Runs at Pester discovery (top level), so -ForEach gets the file list. Hashtables (not
# PSCustomObjects) so Pester spreads their keys into $Rel / $HasBom inside the It.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ps1Files = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
    ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $nonAscii = $false
        foreach ($b in $bytes) { if ($b -gt 0x7F) { $nonAscii = $true; break } }
        @{
            Rel      = $_.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
            HasBom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            NonAscii = $nonAscii
        }
    } | Where-Object { $_.NonAscii }

Describe 'Encoding hygiene: a non-ASCII .ps1 must start with a UTF-8 BOM' {
    It '<Rel> starts with a UTF-8 BOM' -ForEach $ps1Files {
        $HasBom | Should -BeTrue -Because 'PS 5.1 mis-decodes a BOM-less file that holds non-ASCII bytes'
    }
}
