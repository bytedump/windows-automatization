#Requires -Version 5.1

# Tests for build-usb.ps1's security guards: SecureString password handling, minimum-length
# enforcement, base64 encoding, and autounattend.xml overwrite protection. Everything runs
# against TestDrive temp files - no machine state is touched.

BeforeAll {
    $script:BuildUsb = Join-Path $PSScriptRoot '..\..\build-usb.ps1'

    function New-TestTemplate {
        param([string]$Path)
        Set-Content -LiteralPath $Path -Encoding UTF8 -Value @'
<unattend>
  <user>__ADMIN_USER__</user>
  <pw>__ADMIN_PW_B64__</pw>
</unattend>
'@
    }

    # Build a SecureString from plaintext. Empty input returns a zero-length SecureString
    # (ConvertTo-SecureString rejects an empty -String, so construct it directly).
    function New-Pw {
        param([string]$Plain)
        if ([string]::IsNullOrEmpty($Plain)) { return (New-Object System.Security.SecureString) }
        ConvertTo-SecureString $Plain -AsPlainText -Force
    }
}

Describe 'build-usb.ps1 password validation' {
    BeforeEach {
        $script:tpl = Join-Path $TestDrive 'tpl.xml'
        $script:out = Join-Path $TestDrive 'autounattend.xml'
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue  # TestDrive persists across Its
        New-TestTemplate -Path $tpl
    }

    It 'rejects an empty password' {
        { & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw '') } |
            Should -Throw '*empty*'
        Test-Path $out | Should -BeFalse
    }

    It 'accepts a short (non-empty) password and writes the file' {
        # No hard length floor: any non-empty password is accepted.
        & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw 'x') *> $null
        Test-Path $out | Should -BeTrue
    }

    It 'warns (but still writes the file) for a short password under the recommended length' {
        & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw 'ab') `
            -WarningVariable wv -WarningAction SilentlyContinue 6>$null | Out-Null
        Test-Path $out | Should -BeTrue
        "$wv" | Should -BeLike '*recommended*'
    }

    It 'accepts a longer password with no warning and writes the file' {
        & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw 'LongEnough12') `
            -WarningVariable wv -WarningAction SilentlyContinue 6>$null | Out-Null
        Test-Path $out | Should -BeTrue
        "$wv" | Should -BeNullOrEmpty
    }
}

Describe 'build-usb.ps1 account name validation (audit A1)' {
    BeforeEach {
        $script:tpl = Join-Path $TestDrive 'tpl.xml'
        $script:out = Join-Path $TestDrive 'autounattend.xml'
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        New-TestTemplate -Path $tpl
    }

    It 'rejects an account name with XML-special characters' {
        { & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser 'TI & Suporte' -AdminPassword (New-Pw 'LongEnough12') } |
            Should -Throw '*Invalid account name*'
        Test-Path $out | Should -BeFalse
    }

    It 'rejects an account name longer than 20 characters' {
        { & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser ('a' * 21) -AdminPassword (New-Pw 'LongEnough12') } |
            Should -Throw '*Invalid account name*'
        Test-Path $out | Should -BeFalse
    }

    It 'accepts a valid account name and writes well-formed XML' {
        & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser 'setup.admin-1' -AdminPassword (New-Pw 'LongEnough12') *> $null
        Test-Path $out | Should -BeTrue
        { [xml](Get-Content -Raw -LiteralPath $out) } | Should -Not -Throw
    }
}

Describe 'build-usb.ps1 output generation' {
    BeforeEach {
        $script:tpl = Join-Path $TestDrive 'tpl.xml'
        $script:out = Join-Path $TestDrive 'autounattend.xml'
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue  # TestDrive persists across Its
        New-TestTemplate -Path $tpl
    }

    It 'replaces both placeholders and writes well-formed XML' {
        & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw 'LongEnough12') *> $null
        $raw = Get-Content -Raw -LiteralPath $out
        $raw | Should -Not -Match '__ADMIN_USER__|__ADMIN_PW_B64__'
        $raw | Should -Match '<user>setupadmin</user>'
        { [xml]$raw } | Should -Not -Throw
    }

    It 'works with a bare relative -OutPath (legacy invocation from the USB root)' {
        # Regression guard: the wizard's $ConfigPath derivation ran on EVERY invocation, and for a
        # bare filename Split-Path -Parent returns '' -> Join-Path threw before the template was
        # read. Align the process CWD with the PS location, as a real console session has it.
        Push-Location $TestDrive
        $savedCwd = [Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $TestDrive
        try {
            & $BuildUsb -TemplatePath $tpl -OutPath 'autounattend.xml' -AdminUser setupadmin -AdminPassword (New-Pw 'LongEnough12') *> $null
        } finally {
            [Environment]::CurrentDirectory = $savedCwd
            Pop-Location
        }
        Test-Path (Join-Path $TestDrive 'autounattend.xml') | Should -BeTrue
    }

    It 'encodes the password as base64 of UTF-16LE of (password + "Password")' {
        & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw 'LongEnough12') *> $null
        $expected = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('LongEnough12' + 'Password'))
        (Get-Content -Raw -LiteralPath $out) | Should -Match ([regex]::Escape($expected))
    }
}

Describe 'build-usb.ps1 overwrite guard' {
    BeforeEach {
        $script:tpl = Join-Path $TestDrive 'tpl.xml'
        $script:out = Join-Path $TestDrive 'autounattend.xml'
        New-TestTemplate -Path $tpl
        Set-Content -LiteralPath $out -Value 'OLD' -Encoding UTF8   # pre-existing file
    }

    It 'refuses to overwrite an existing autounattend.xml without -Force' {
        { & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw 'LongEnough12') } |
            Should -Throw '*Refusing to overwrite*'
        (Get-Content -Raw -LiteralPath $out).Trim() | Should -BeExactly 'OLD'   # untouched
    }

    It 'overwrites an existing file when -Force is passed' {
        & $BuildUsb -TemplatePath $tpl -OutPath $out -AdminUser setupadmin -AdminPassword (New-Pw 'LongEnough12') -Force *> $null
        (Get-Content -Raw -LiteralPath $out) | Should -Match '<user>setupadmin</user>'
    }
}
