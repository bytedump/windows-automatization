#Requires -Version 5.1

# Unit tests for the file helpers in cleanup.ps1 (flag detection, idempotent staging
# removal). cleanup.ps1 is dot-sourced with -LoadOnly so only the functions load - no
# registry, scheduled-task, or real ProgramData state is touched. The HKLM / task
# steps are validated on a VM.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\cleanup.ps1') -LoadOnly
}

Describe 'Test-UserDoneFlag' {
    BeforeEach {
        # Avoid the name 'StateDir' here: it would collide (case-insensitively) with the
        # dot-sourced script param of the same name.
        $script:dir = Join-Path $TestDrive 'CorpSetup'
        Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
    }

    It 'returns $false when the flag is absent' {
        Test-UserDoneFlag -StateDir $script:dir | Should -BeFalse
    }

    It 'returns $true when the flag exists' {
        Set-Content -LiteralPath (Join-Path $script:dir 'user-done') -Value 'x' -Encoding UTF8
        Test-UserDoneFlag -StateDir $script:dir | Should -BeTrue
    }

    It 'returns $false when the folder does not exist' {
        Test-UserDoneFlag -StateDir (Join-Path $TestDrive 'nope') | Should -BeFalse
    }
}

Describe 'Remove-StagingFolder' {
    It 'removes an existing folder (with contents) and returns $true' {
        $d = Join-Path $TestDrive 'staging1'
        New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'sub\f.txt') -Value 'x' -Encoding UTF8
        Remove-StagingFolder -StateDir $d | Should -BeTrue
        Test-Path -LiteralPath $d | Should -BeFalse
    }

    It 'is idempotent: returns $false when the folder is already gone' {
        $d = Join-Path $TestDrive 'staging2'
        Remove-StagingFolder -StateDir $d | Should -BeFalse
    }
}

Describe 'Save-PhaseBLogs' {
    It 'copies the logs folder to the destination root and returns $true' {
        $sd = Join-Path $TestDrive 'sd1'
        New-Item -ItemType Directory -Path (Join-Path $sd 'logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sd 'logs\phase-b-joao.log') -Value 'log' -Encoding UTF8
        $destRoot = Join-Path $TestDrive 'destroot1'
        Save-PhaseBLogs -StateDir $sd -DestRoot $destRoot | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destRoot 'corp-phaseb-logs\logs\phase-b-joao.log') | Should -BeTrue
    }

    It 'returns $false (no-op) when there is no logs folder' {
        $sd = Join-Path $TestDrive 'sd2'
        New-Item -ItemType Directory -Path $sd -Force | Out-Null
        Save-PhaseBLogs -StateDir $sd -DestRoot (Join-Path $TestDrive 'destroot2') | Should -BeFalse
    }
}
