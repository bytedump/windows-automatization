#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the real autounattend.xml from autounattend.template.xml, injecting
    the bootstrap admin account name and password. Run ONCE, when preparing the USB.

.DESCRIPTION
    The repository ships only the TEMPLATE (with __ADMIN_USER__ / __ADMIN_PW_B64__
    placeholders) — no secret is versioned. This script fills the placeholders and
    writes autounattend.xml to the USB root. The generated file holds the password
    (base64), so it is in .gitignore — NEVER commit it.

    The autounattend password is BOOTSTRAP only: setup.ps1 rotates it on first login
    to the real password from config.ps1. The NAME entered here MUST match
    $AdminAccount in config.ps1 (setup.ps1 uses that name to rotate the password).

.EXAMPLE
    .\build-usb.ps1
    # Prompts for name and password interactively, generates .\autounattend.xml

.EXAMPLE
    .\build-usb.ps1 -AdminUser setupadmin -OutPath E:\autounattend.xml
    # Prompts only for the password (hidden), writes straight to the USB root (E:)
#>
[CmdletBinding()]
param(
    [string]$TemplatePath,
    [string]$OutPath,
    [string]$AdminUser,
    [string]$AdminPassword
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the script's own folder. $PSScriptRoot can be EMPTY when referenced inside a
# param() default (it is not always populated at parameter-binding time, e.g. launched via
# `powershell -File`), which made Join-Path fail. Resolve it here in the body with a fallback
# and default the paths from it instead of in the param block.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $TemplatePath) { $TemplatePath = Join-Path $ScriptDir 'autounattend.template.xml' }
if (-not $OutPath)      { $OutPath      = Join-Path $ScriptDir 'autounattend.xml' }

if (-not (Test-Path $TemplatePath)) {
    throw "Template not found: $TemplatePath"
}

# --- Account name ---
if (-not $AdminUser) {
    $AdminUser = (Read-Host 'Bootstrap admin account name (e.g. setupadmin)').Trim()
}
if (-not $AdminUser) { throw 'Account name cannot be empty.' }

# --- Password (hidden; converted to plain text only long enough to build the base64) ---
if (-not $AdminPassword) {
    $sec  = Read-Host 'Bootstrap admin account password' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $AdminPassword) { throw 'Password cannot be empty.' }

# Windows expects the value as base64 of UTF-16LE of (password + "Password" suffix),
# for both LocalAccount and AutoLogon. Same value in both places.
$pwB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($AdminPassword + 'Password'))

$xml = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
$xml = $xml.Replace('__ADMIN_USER__', $AdminUser).Replace('__ADMIN_PW_B64__', $pwB64)

if ($xml -match '__ADMIN_USER__|__ADMIN_PW_B64__') {
    throw 'An unreplaced placeholder remains in the XML - aborting.'
}

# UTF-8 without BOM (autounattend expects UTF-8).
[System.IO.File]::WriteAllText($OutPath, $xml, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "OK: autounattend.xml generated at $OutPath" -ForegroundColor Green
Write-Host "Bootstrap account: $AdminUser" -ForegroundColor Green
Write-Host ""
Write-Host "REMINDERS:" -ForegroundColor Yellow
Write-Host "  - In config.ps1, `$AdminAccount MUST be '$AdminUser'." -ForegroundColor Yellow
Write-Host "  - The generated autounattend.xml holds the password - NEVER commit it (already in .gitignore)." -ForegroundColor Yellow
Write-Host "  - This is the BOOTSTRAP password; setup.ps1 rotates it to the real one (`$AdminNewPass) on first login." -ForegroundColor Yellow
