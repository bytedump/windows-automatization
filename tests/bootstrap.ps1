#Requires -Version 5.1
param(
    # By default setup.ps1 runs INTERACTIVELY (the GUI, production-like). Pass -Headless for
    # the automated assertion path: setup.ps1 -Unattended with test data, no GUI.
    [switch]$Headless,
    # -PhaseB: in-session smoke of the two-phase handoff (stage -> Phase B -> cleanup) and its
    # teardown contract. The Sandbox cannot reboot + AutoLogon a second user, so this is an
    # approximation; real per-user + reboot validation stays VM-only. THROWAWAY SANDBOX ONLY
    # (it briefly writes a test password to HKLM, which cleanup.ps1 then zeroes - see below).
    [switch]$PhaseB
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

# ============================================================
# -PhaseB: in-session smoke of the two-phase handoff (see the param note). Runs the REAL
# staging (setup.ps1 -EnableHandoff -NoReboot) -> the staged phase-b.ps1 (per-user effects
# land in THIS admin session's profile, not the created user's) -> the staged cleanup.ps1,
# asserting the staging + teardown contract: state.json, the two tasks, the AutoLogon brecha
# armed then zeroed, the staging folder removed.
#
# SECURITY: -EnableHandoff arms a one-shot AutoLogon, writing the TEST password in plaintext
# to HKLM\...\Winlogon (the declared brecha). cleanup.ps1 zeroes + verifies it here, and the
# Sandbox is disposable. NEVER run -PhaseB outside a throwaway sandbox/VM.
# ============================================================
if ($PhaseB) {
    $stateDir = Join-Path $env:ProgramData 'CorpSetup'
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:pbFails = [System.Collections.Generic.List[string]]::new()

    function Assert-PhaseB {
        param([string]$Label, [bool]$Ok)
        $tag = if ($Ok) { '[PASS]' } else { '[FAIL]' }
        $col = if ($Ok) { 'Green' } else { 'Red' }
        Write-Host "        $tag $Label" -ForegroundColor $col
        if (-not $Ok) { $script:pbFails.Add($Label) }
    }
    # StrictMode-safe presence test for a registry value (accessing an absent property throws).
    function Test-RegProp {
        param([string]$Path, [string]$Name)
        $p = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
        return [bool]($p -and $p.PSObject.Properties[$Name])
    }

    Write-Host "  [4/4] Phase B handoff smoke (stage -> Phase B -> cleanup, in-session)..." -ForegroundColor White
    Write-Host "        NOTE: per-user effects land in THIS session; real reboot+AutoLogon is VM-only." -ForegroundColor DarkYellow
    Write-Host ""

    # PS 5.1 parses the staged scripts off the simulated USB; ensure a UTF-8 BOM (mirrors the
    # interactive path's setup.ps1 handling) so all three load cleanly.
    foreach ($f in 'setup.ps1', 'phase-b.ps1', 'cleanup.ps1') {
        $fp = Join-Path $usbDir $f
        if (Test-Path $fp) {
            $raw = [System.IO.File]::ReadAllText($fp, [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($fp, $raw, (New-Object System.Text.UTF8Encoding $true))
        }
    }
    Set-Location $usbDir

    # 1) Stage + arm (NO reboot). The TI / empresa.com.br fixture exercises the signature path.
    Write-Host "  -> Staging (setup.ps1 -EnableHandoff -NoReboot)..." -ForegroundColor Cyan
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $usbDir 'setup.ps1') `
        -Unattended -EnableHandoff -NoReboot `
        -TestFullName 'Test User' -TestUsername 'test.user' -TestDomain 'empresa.com.br' -TestSector 'TI'
    Assert-PhaseB 'state.json staged'                 (Test-Path -LiteralPath (Join-Path $stateDir 'state.json'))
    Assert-PhaseB 'phase-b.ps1 staged'                (Test-Path -LiteralPath (Join-Path $stateDir 'phase-b.ps1'))
    Assert-PhaseB 'cleanup.ps1 staged'                (Test-Path -LiteralPath (Join-Path $stateDir 'cleanup.ps1'))
    Assert-PhaseB 'task CorpSetup-PhaseB-User'        ([bool](Get-ScheduledTask -TaskName 'CorpSetup-PhaseB-User'   -ErrorAction SilentlyContinue))
    Assert-PhaseB 'task CorpSetup-PhaseB-System'      ([bool](Get-ScheduledTask -TaskName 'CorpSetup-PhaseB-System' -ErrorAction SilentlyContinue))
    Assert-PhaseB 'AutoLogon armed (DefaultPassword)' (Test-RegProp $winlogon 'DefaultPassword')

    # 2) Phase B (staged copy = what production runs). Per-user effects in THIS session.
    Write-Host "  -> Phase B (staged phase-b.ps1)..." -ForegroundColor Cyan
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stateDir 'phase-b.ps1')
    $sigHtm = Join-Path $env:APPDATA 'Microsoft\Signatures\test.user.htm'
    Assert-PhaseB 'signature written to %APPDATA%' (Test-Path -LiteralPath $sigHtm)
    Assert-PhaseB 'user-done flag dropped'         (Test-Path -LiteralPath (Join-Path $stateDir 'user-done'))

    # 3) Cleanup (staged copy). Short timeout - the flag is already present.
    Write-Host "  -> Cleanup (staged cleanup.ps1)..." -ForegroundColor Cyan
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stateDir 'cleanup.ps1') -TimeoutSeconds 20 -PollSeconds 2
    Assert-PhaseB 'AutoLogon password zeroed' (-not (Test-RegProp $winlogon 'DefaultPassword'))
    Assert-PhaseB 'AutoAdminLogon = 0'        ((-not (Test-RegProp $winlogon 'AutoAdminLogon')) -or ((Get-ItemProperty $winlogon).AutoAdminLogon -eq '0'))
    Assert-PhaseB 'user task unregistered'    (-not (Get-ScheduledTask -TaskName 'CorpSetup-PhaseB-User'   -ErrorAction SilentlyContinue))
    Assert-PhaseB 'system task unregistered'  (-not (Get-ScheduledTask -TaskName 'CorpSetup-PhaseB-System' -ErrorAction SilentlyContinue))
    Assert-PhaseB 'staging folder removed'    (-not (Test-Path -LiteralPath $stateDir))

    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor Cyan
    if ($script:pbFails.Count -eq 0) {
        Write-Host "   PHASE B SMOKE: PASSED (contract held in-session)" -ForegroundColor Green
    } else {
        Write-Host "   PHASE B SMOKE: FAILED ($($script:pbFails.Count)): $($script:pbFails -join '; ')" -ForegroundColor Red
    }
    Write-Host "  ======================================" -ForegroundColor Cyan
    Write-Host "   Reminder: real reboot + new-user AutoLogon is validated on a VM, not here." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to close the Sandbox"
    if ($script:pbFails.Count -eq 0) { exit 0 } else { exit 1 }
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
