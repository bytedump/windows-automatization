#Requires -Version 5.1
<#
.SYNOPSIS
    Gera o autounattend.xml real a partir do autounattend.template.xml, injetando
    o nome e a senha da conta admin bootstrap. Roda UMA vez, ao preparar o pendrive.

.DESCRIPTION
    O repositorio guarda so o TEMPLATE (com placeholders __ADMIN_USER__ /
    __ADMIN_PW_B64__) — nenhum segredo e' versionado. Este script preenche os
    placeholders e grava o autounattend.xml na raiz da USB. O arquivo gerado tem a
    senha (base64) e por isso esta no .gitignore — NUNCA commitar.

    A senha do autounattend e' so de BOOTSTRAP: o setup.ps1 a troca no 1o login pela
    senha real do config.ps1. O NOME informado aqui DEVE bater com $AdminAccount no
    config.ps1 (o setup.ps1 usa esse nome pra trocar a senha).

.EXAMPLE
    .\build-usb.ps1
    # Pergunta nome e senha interativamente, gera .\autounattend.xml

.EXAMPLE
    .\build-usb.ps1 -AdminUser setupadmin -OutPath E:\autounattend.xml
    # Pergunta so a senha (escondida), grava direto na raiz do pendrive (E:)
#>
[CmdletBinding()]
param(
    [string]$TemplatePath = (Join-Path $PSScriptRoot 'autounattend.template.xml'),
    [string]$OutPath      = (Join-Path $PSScriptRoot 'autounattend.xml'),
    [string]$AdminUser,
    [string]$AdminPassword
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $TemplatePath)) {
    throw "Template nao encontrado: $TemplatePath"
}

# --- Nome da conta ---
if (-not $AdminUser) {
    $AdminUser = (Read-Host 'Nome da conta admin bootstrap (ex: setupadmin)').Trim()
}
if (-not $AdminUser) { throw 'Nome da conta nao pode ser vazio.' }

# --- Senha (escondida; convertida pra texto so o tempo de gerar o base64) ---
if (-not $AdminPassword) {
    $sec  = Read-Host 'Senha da conta admin bootstrap' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $AdminPassword) { throw 'Senha nao pode ser vazia.' }

# O Windows espera o valor em base64 de UTF-16LE de (senha + sufixo "Password"),
# tanto p/ LocalAccount quanto p/ AutoLogon. Mesmo valor nos dois lugares.
$pwB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($AdminPassword + 'Password'))

$xml = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
$xml = $xml.Replace('__ADMIN_USER__', $AdminUser).Replace('__ADMIN_PW_B64__', $pwB64)

if ($xml -match '__ADMIN_USER__|__ADMIN_PW_B64__') {
    throw 'Sobrou placeholder nao substituido no XML — abortando.'
}

# UTF-8 sem BOM (autounattend espera UTF-8).
[System.IO.File]::WriteAllText($OutPath, $xml, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "OK: autounattend.xml gerado em $OutPath" -ForegroundColor Green
Write-Host "Conta bootstrap: $AdminUser" -ForegroundColor Green
Write-Host ""
Write-Host "LEMBRETES:" -ForegroundColor Yellow
Write-Host "  - No config.ps1, \$AdminAccount DEVE ser '$AdminUser'." -ForegroundColor Yellow
Write-Host "  - O autounattend.xml gerado tem a senha — NUNCA commitar (ja esta no .gitignore)." -ForegroundColor Yellow
Write-Host "  - Esta e' a senha BOOTSTRAP; o setup.ps1 troca pela real (\$AdminNewPass) no 1o login." -ForegroundColor Yellow
