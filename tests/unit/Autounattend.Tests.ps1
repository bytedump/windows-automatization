#Requires -Version 5.1

# Tests for autounattend.template.xml: well-formed XML and the FirstLogonCommands exit-code
# propagation contract, so a failed setup.ps1 surfaces to Windows Setup instead of reporting
# success. Reads the file only - no machine state.

BeforeAll {
    $script:XmlPath = Join-Path $PSScriptRoot '..\..\autounattend.template.xml'
    $script:Raw = Get-Content -Raw -LiteralPath $XmlPath
}

Describe 'autounattend.template.xml' {
    It 'is well-formed XML' {
        { [xml]$Raw } | Should -Not -Throw
    }

    It 'launches setup.ps1 with -PassThru and propagates its exit code' {
        $Raw | Should -Match '-Wait -PassThru'
        $Raw | Should -Match 'exit \$p\.ExitCode'
    }

    It 'exits non-zero (2) when the setup USB is not found' {
        $Raw | Should -Match 'Out-Null; exit 2'
    }
}
