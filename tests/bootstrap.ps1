#Requires -Version 5.1
param(
    # By default setup.ps1 runs INTERACTIVELY (the GUI, production-like). Pass -Headless for
    # the automated assertion path: setup.ps1 -Unattended with test data, no GUI.
    [switch]$Headless
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================
# bootstrap.ps1 - Runs INSIDE Windows Sandbox at login
# Simulates a USB drive and runs setup.ps1 in an isolated environment.
# Default: interactive (production-like GUI). -Headless: automated assertion.
# ============================================================

$usbDir = "C:\USB"

Write-Host ""
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "   BOOTSTRAP TEST - SANDBOX" -ForegroundColor Cyan
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host ""

# --- Diagnostics: C:\Scripts must exist with setup.ps1 ---
if (-not (Test-Path "C:\Scripts")) {
    Write-Host "  ERROR: C:\Scripts not found." -ForegroundColor Red
    Write-Host "  Cause: the Sandbox mapping failed or the Sandbox was opened directly." -ForegroundColor Red
    Write-Host "  Fix: run prep.ps1 on Windows (not WSL) and use the sandbox.wsb it generates." -ForegroundColor Yellow
    Read-Host "  Press Enter to close"
    exit 1
}

if (-not (Test-Path "C:\Scripts\setup.ps1")) {
    Write-Host "  ERROR: C:\Scripts\setup.ps1 not found." -ForegroundColor Red
    Write-Host "  Files in C:\Scripts:" -ForegroundColor Yellow
    Get-ChildItem "C:\Scripts" | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor DarkGray }
    Write-Host "  Fix: check that prep.ps1 copied the scripts correctly." -ForegroundColor Yellow
    Read-Host "  Press Enter to close"
    exit 1
}

# --- Mount the simulated USB ---
Write-Host "  [1/4] Creating the simulated USB at $usbDir..." -ForegroundColor White
New-Item -ItemType Directory -Force -Path $usbDir | Out-Null

Copy-Item -Path "C:\Scripts\*" -Destination $usbDir -Recurse -Force
Write-Host "        scripts copied from C:\Scripts" -ForegroundColor DarkGray

# Overlay the test fixtures (printers.json, assinatura-2026/) AFTER, so the fixtures
# take priority over the real files
Copy-Item -Path "C:\Tests\usb-sim\*" -Destination $usbDir -Recurse -Force
Write-Host "        test fixtures overlaid" -ForegroundColor DarkGray

# --- Replace the real config.ps1 with the test version ---
Write-Host "  [2/4] Injecting test credentials..." -ForegroundColor White
if (-not (Test-Path "C:\Tests\test-config.ps1")) {
    Write-Host "  ERROR: C:\Tests\test-config.ps1 not found." -ForegroundColor Red
    Read-Host "  Press Enter to close"; exit 1
}
Copy-Item -Path "C:\Tests\test-config.ps1" -Destination "$usbDir\config.ps1" -Force
Write-Host "        test-config.ps1 -> $usbDir\config.ps1" -ForegroundColor DarkGray

# --- Pre-create the setupadmin account (setup.ps1 rotates its password; without it, an ERROR is expected in the sandbox) ---
Write-Host "  [3/4] Preparing the test setupadmin account..." -ForegroundColor White
if (-not (Get-LocalUser -Name 'setupadmin' -ErrorAction SilentlyContinue)) {
    $bootstrapPass = ConvertTo-SecureString 'Bootstrap@Sandbox1!' -AsPlainText -Force
    New-LocalUser -Name 'setupadmin' -Password $bootstrapPass -ErrorAction SilentlyContinue | Out-Null
    Write-Host "        setupadmin created" -ForegroundColor DarkGray
}

# --- Run setup.ps1 (interactive GUI by default; -Headless for the automated assertion) ---
Write-Host "  [4/4] Running setup.ps1$(if ($Headless) { ' -Unattended (headless)' } else { ' (interactive GUI - production-like)' })..." -ForegroundColor White
Write-Host ""

# Ensure UTF-8 BOM in setup.ps1 so PowerShell 5.1 parses it correctly
$setupFile = "$usbDir\setup.ps1"
if (-not (Test-Path $setupFile)) {
    Write-Host "  ERROR: $setupFile does not exist (copy from C:\Scripts failed)." -ForegroundColor Red
    Read-Host "  Press Enter to close"; exit 1
}
$raw = [System.IO.File]::ReadAllText($setupFile, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($setupFile, $raw, (New-Object System.Text.UTF8Encoding $true))

Set-Location $usbDir
if ($Headless) {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupFile `
        -Unattended -TestFullName 'Test User' -TestUsername 'test.user'
} else {
    # Production-like: the GUI appears. Fill it with the test fixtures and click Start:
    #   First = Test | Last = User (Username auto-fills to test.user) | domain = empresa.com.br | sector = TI | printer = Test Printer
    Write-Host "  Fill the GUI (First 'Test', Last 'User' -> Username auto 'test.user'; domain empresa.com.br, sector TI, printer 'Test Printer') and click Start." -ForegroundColor DarkGray
    Write-Host ""
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupFile
}
$setupExit = $LASTEXITCODE

# --- Evaluate the result: exit code + count of [ERROR]/[FATAL] in the log (the real assertion) ---
$logFile = "$env:USERPROFILE\Desktop\win11_setup_log.txt"
Write-Host ""
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "   TEST RESULT" -ForegroundColor Cyan
Write-Host "  ======================================" -ForegroundColor Cyan

$errCount = 0
if (Test-Path $logFile) {
    Write-Host ""
    Get-Content $logFile | ForEach-Object {
        $color = if ($_ -match '\[OK\]')           { 'Green'  } `
            elseif ($_ -match '\[WARN\]')          { 'Yellow' } `
            elseif ($_ -match '\[(ERROR|FATAL)\]') { 'Red'    } `
            else                                   { 'Gray'   }
        Write-Host "  $_" -ForegroundColor $color
    }
    $errCount = @(Get-Content $logFile | Select-String -Pattern '\[(ERROR|FATAL)\]').Count
} else {
    Write-Host "  Log not found: $logFile" -ForegroundColor Red
}

Write-Host ""
Write-Host "  --------------------------------------" -ForegroundColor Cyan
if ($setupExit -eq 0 -and $errCount -eq 0) {
    Write-Host "   RESULT: PASSED (exit 0, 0 errors)" -ForegroundColor Green
} else {
    Write-Host "   RESULT: FAILED (exit=$setupExit, $errCount ERROR/FATAL line(s))" -ForegroundColor Red
    Write-Host "   Review the red lines above." -ForegroundColor Yellow
}
Write-Host "  --------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Full log: $logFile" -ForegroundColor Yellow
Write-Host ""
Read-Host "  Press Enter to close the Sandbox"
