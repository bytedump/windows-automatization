#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# prep.ps1 — Prepara e abre o Windows Sandbox para teste
# Executar no Windows (PowerShell nativo, NAO no WSL)
# ============================================================
# Uso: powershell.exe -ExecutionPolicy Bypass -File prep.ps1

$repoRoot   = Split-Path $PSScriptRoot -Parent
$stagingDir = "C:\SandboxTest"
$scriptsOut = "$stagingDir\scripts"
$testsOut   = "$stagingDir\tests"

Write-Host ""
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "   PREPARANDO SANDBOX DE TESTE" -ForegroundColor Cyan
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Repo origem : $repoRoot" -ForegroundColor Yellow
Write-Host "  Staging     : $stagingDir" -ForegroundColor Yellow
Write-Host ""

# --- Limpeza e recriação do staging ---
Write-Host "  [1/4] Criando diretório de staging..." -ForegroundColor White
if (Test-Path $stagingDir) {
    Remove-Item $stagingDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $scriptsOut | Out-Null
New-Item -ItemType Directory -Force -Path $testsOut  | Out-Null

# --- Copiar scripts do repo (excluindo o que não deve ir pro USB simulado) ---
Write-Host "  [2/4] Copiando scripts do repo..." -ForegroundColor White
$excludeDirs = @('tests', '.git', 'automatizacaoCloud', 'assinatura-2026')
$excludeFiles = @('config.ps1', 'printers.json')   # config.ps1: credenciais reais. printers.json: IPs internos de producao — o usb-sim traz a fixture de teste

Get-ChildItem -Path $repoRoot | Where-Object {
    $_.Name -notin $excludeDirs -and $_.Name -notin $excludeFiles
} | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $scriptsOut -Recurse -Force
    Write-Host "        copiado: $($_.Name)" -ForegroundColor DarkGray
}

# --- Copiar fixtures de teste ---
Write-Host "  [3/4] Copiando fixtures de teste..." -ForegroundColor White
Copy-Item -Path "$PSScriptRoot\*" -Destination $testsOut -Recurse -Force
Write-Host "        copiado: tests/" -ForegroundColor DarkGray

# --- Gerar sandbox.wsb com paths absolutos corretos ---
Write-Host "  [4/4] Gerando sandbox.wsb..." -ForegroundColor White
$wsbContent = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$scriptsOut</HostFolder>
      <SandboxFolder>C:\Scripts</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$testsOut</HostFolder>
      <SandboxFolder>C:\Tests</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>cmd.exe /c "ping -n 20 127.0.0.1 >nul &amp;&amp; start &quot;Bootstrap&quot; powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\Tests\bootstrap.ps1"</Command>
  </LogonCommand>
</Configuration>
"@

$wsbPath = "$stagingDir\sandbox.wsb"
Set-Content -Path $wsbPath -Value $wsbContent -Encoding UTF8
Write-Host "        gerado: $wsbPath" -ForegroundColor DarkGray

Write-Host ""
Write-Host "  Pronto! Abrindo Windows Sandbox..." -ForegroundColor Green
Write-Host "  bootstrap.ps1 rodara automaticamente no login." -ForegroundColor Green
Write-Host "  Preencha o formulario GUI quando aparecer." -ForegroundColor Green
Write-Host ""
Write-Host "  Log do teste: C:\Users\WDAGUtilityAccount\Desktop\win11_setup_log.txt" -ForegroundColor Yellow
Write-Host ""

Start-Process $wsbPath
