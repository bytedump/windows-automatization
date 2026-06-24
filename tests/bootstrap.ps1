#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================
# bootstrap.ps1 - Roda DENTRO do Windows Sandbox no login
# Simula pendrive USB e executa setup.ps1 em ambiente isolado
# ============================================================

$usbDir = "C:\USB"

Write-Host ""
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "   BOOTSTRAP DE TESTE - SANDBOX" -ForegroundColor Cyan
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host ""

# --- Diagnostico: C:\Scripts precisa existir com setup.ps1 ---
if (-not (Test-Path "C:\Scripts")) {
    Write-Host "  ERRO: C:\Scripts nao encontrado." -ForegroundColor Red
    Write-Host "  Causa: mapeamento do Sandbox falhou ou Sandbox foi aberto diretamente." -ForegroundColor Red
    Write-Host "  Solucao: execute prep.ps1 no Windows (nao no WSL) e use o sandbox.wsb gerado por ele." -ForegroundColor Yellow
    Read-Host "  Enter para fechar"
    exit 1
}

if (-not (Test-Path "C:\Scripts\setup.ps1")) {
    Write-Host "  ERRO: C:\Scripts\setup.ps1 nao encontrado." -ForegroundColor Red
    Write-Host "  Arquivos em C:\Scripts:" -ForegroundColor Yellow
    Get-ChildItem "C:\Scripts" | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor DarkGray }
    Write-Host "  Solucao: verifique se prep.ps1 copiou os scripts corretamente." -ForegroundColor Yellow
    Read-Host "  Enter para fechar"
    exit 1
}

# --- Montar USB simulado ---
Write-Host "  [1/4] Criando pendrive simulado em $usbDir..." -ForegroundColor White
New-Item -ItemType Directory -Force -Path $usbDir | Out-Null

Copy-Item -Path "C:\Scripts\*" -Destination $usbDir -Recurse -Force
Write-Host "        scripts copiados de C:\Scripts" -ForegroundColor DarkGray

# Sobrepoe com fixtures de teste (printers.json, assinatura-2026/)
# feito DEPOIS para que fixtures ganhem prioridade sobre arquivos reais
Copy-Item -Path "C:\Tests\usb-sim\*" -Destination $usbDir -Recurse -Force
Write-Host "        fixtures de teste sobrepostos" -ForegroundColor DarkGray

# --- Substituir config.ps1 real pela versao de teste ---
Write-Host "  [2/4] Injetando credenciais de teste..." -ForegroundColor White
if (-not (Test-Path "C:\Tests\test-config.ps1")) {
    Write-Host "  ERRO: C:\Tests\test-config.ps1 nao encontrado." -ForegroundColor Red
    Read-Host "  Enter para fechar"; exit 1
}
Copy-Item -Path "C:\Tests\test-config.ps1" -Destination "$usbDir\config.ps1" -Force
Write-Host "        test-config.ps1 -> $usbDir\config.ps1" -ForegroundColor DarkGray

# --- Pre-criar conta setupadmin (setup.ps1 troca a senha dela; sem ela, ERROR esperado no sandbox) ---
Write-Host "  [3/4] Preparando conta setupadmin de teste..." -ForegroundColor White
if (-not (Get-LocalUser -Name 'setupadmin' -ErrorAction SilentlyContinue)) {
    $bootstrapPass = ConvertTo-SecureString 'Bootstrap@Sandbox1!' -AsPlainText -Force
    New-LocalUser -Name 'setupadmin' -Password $bootstrapPass -ErrorAction SilentlyContinue | Out-Null
    Write-Host "        setupadmin criada" -ForegroundColor DarkGray
}

# --- Executar setup.ps1 em modo -Unattended (headless: sem GUI travando o teste) ---
Write-Host "  [4/4] Executando setup.ps1 -Unattended..." -ForegroundColor White
Write-Host ""

# Garante UTF-8 BOM em setup.ps1 para PowerShell 5.1 parsear corretamente
$setupFile = "$usbDir\setup.ps1"
if (-not (Test-Path $setupFile)) {
    Write-Host "  ERRO: $setupFile nao existe (copia de C:\Scripts falhou)." -ForegroundColor Red
    Read-Host "  Enter para fechar"; exit 1
}
$raw = [System.IO.File]::ReadAllText($setupFile, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($setupFile, $raw, (New-Object System.Text.UTF8Encoding $true))

Set-Location $usbDir
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupFile `
    -Unattended -TestFullName 'Fulano de Teste' -TestUsername 'fulano.teste'
$setupExit = $LASTEXITCODE

# --- Avaliar resultado: exit code + contagem de [ERROR]/[FATAL] no log (asercao real) ---
$logFile = "$env:USERPROFILE\Desktop\win11_setup_log.txt"
Write-Host ""
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "   RESULTADO DO TESTE" -ForegroundColor Cyan
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
    Write-Host "  Log nao encontrado: $logFile" -ForegroundColor Red
}

Write-Host ""
Write-Host "  --------------------------------------" -ForegroundColor Cyan
if ($setupExit -eq 0 -and $errCount -eq 0) {
    Write-Host "   RESULTADO: PASSOU (exit 0, 0 erros)" -ForegroundColor Green
} else {
    Write-Host "   RESULTADO: FALHOU (exit=$setupExit, $errCount linha(s) ERROR/FATAL)" -ForegroundColor Red
    Write-Host "   Revise as linhas vermelhas acima." -ForegroundColor Yellow
}
Write-Host "  --------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Log completo: $logFile" -ForegroundColor Yellow
Write-Host ""
Read-Host "  Enter para fechar o Sandbox"
