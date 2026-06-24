#Requires -Version 5.1
param(
    [switch]$Unattended,
    [string]$TestFullName  = 'Teste Usuario',
    [string]$TestUsername  = 'teste.usuario',
    [string]$TestDomain    = '',
    [string]$TestSector    = '',
    [switch]$TestStaticIp,
    [string]$TestIpAddress = '',
    [switch]$TestWebAgent
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# setup.ps1 — Windows 11 Setup
# Executado automaticamente pelo autounattend.xml no primeiro login
# Requer: config.ps1 na raiz do pendrive (gitignored, nunca commitar)
# ============================================================

$LogFile      = "$env:USERPROFILE\Desktop\win11_setup_log.txt"
$ScriptDir    = $PSScriptRoot
$script:Erros = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Level, [string]$Msg)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
    if ($Level -in 'ERROR', 'FATAL') {
        $script:Erros.Add("[$Level] $Msg") | Out-Null
    }
}

# Avalia o exit code de um instalador e loga OK/ERROR (em vez de assumir OK).
# 3010 (reboot required) conta como sucesso para MSI.
function Write-ProcResult {
    param([string]$Name, $Proc, [int[]]$OkCodes = @(0))
    if ($null -eq $Proc) { Write-Log 'ERROR' "${Name}: processo nao iniciou"; return }
    if ($OkCodes -contains $Proc.ExitCode) {
        Write-Log 'OK' "$Name exit $($Proc.ExitCode)"
    } else {
        Write-Log 'ERROR' "$Name falhou (exit $($Proc.ExitCode))"
    }
}

# Trap global = rede final para erro terminante NAO tratado por try/catch.
# Aborta com exit 1 (em vez de 'continue') para nao seguir sobre estado inconsistente
# e para sinalizar falha ao chamador (run.bat checa %errorlevel%).
trap {
    $msg = "Erro fatal nao tratado na linha $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    Write-Log 'FATAL' $msg
    exit 1
}

# ============================================================
# FASE 1 — Carregar config.ps1 do pendrive
# ============================================================

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Log 'FATAL' "Falha ao carregar assemblies GUI: $($_.Exception.Message)"
    exit 1
}

$ConfigFile = Join-Path $ScriptDir 'config.ps1'
if (-not (Test-Path $ConfigFile)) {
    [System.Windows.Forms.MessageBox]::Show(
        "config.ps1 nao encontrado em: $ScriptDir`nColoque config.ps1 na raiz do pendrive e execute novamente.",
        'Setup — Erro', 'OK', 'Error') | Out-Null
    exit 1
}
try {
    . $ConfigFile
    Write-Log 'OK' "config.ps1 carregado de: $ConfigFile"
} catch {
    Write-Log 'FATAL' "Falha ao executar config.ps1: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "Erro ao carregar config.ps1:`n$($_.Exception.Message)",
        'Setup — Erro Fatal', 'OK', 'Error') | Out-Null
    exit 1
}

# Valida variaveis obrigatorias do config ANTES de usar (sob StrictMode, indexar uma
# variavel ausente vira FATAL generico — aqui da uma mensagem acionavel e aborta cedo).
$RequiredConfig = @('AdminAccount', 'AdminNewPass', 'UserInitialPass', 'EmailDomains', 'PathSignatures')
$missing = $RequiredConfig | Where-Object {
    $v = Get-Variable $_ -ErrorAction SilentlyContinue
    (-not $v) -or ($null -eq $v.Value) -or (($v.Value -is [string]) -and ($v.Value.Trim() -eq ''))
}
if ($missing) {
    $msg = "config.ps1 nao define: " + ($missing -join ', ')
    Write-Log 'FATAL' $msg
    [System.Windows.Forms.MessageBox]::Show($msg, 'Setup — config.ps1 incompleto', 'OK', 'Error') | Out-Null
    exit 1
}

# Config OPCIONAL: se config.ps1 omitir, criar com $null para nao estourar StrictMode
# mais a frente (ex.: `if ($WifiSSID)` indexa a variavel ausente e e' FATAL sob StrictMode).
# Todas sao usadas sob guarda (`if ($Var)`) ou validadas no ponto de uso.
$OptionalConfig = @('WifiSSID', 'WifiPass', 'SharePath', 'ShareUser', 'SharePass',
                    'WallpaperFile', 'StaticPrefixLength', 'StaticGateway', 'DnsServers')
foreach ($o in $OptionalConfig) {
    if (-not (Get-Variable -Name $o -ErrorAction SilentlyContinue)) {
        New-Variable -Name $o -Value $null
    }
}

# Ativar Windows com chave OEM do firmware UEFI (Dell OA3)
try {
    $oemKey = (Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey
    if ($oemKey -and $oemKey.Trim().Length -gt 0) {
        cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ipk $oemKey 2>&1 | Out-Null
        # /ipk via cscript e' sincrono (cscript espera o script); o /ato pode seguir direto.
        cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato 2>&1 | Out-Null
        Write-Log 'OK' "Chave OEM do firmware aplicada e ativacao solicitada"
    } else {
        Write-Log 'WARN' "Chave OEM nao encontrada no firmware UEFI"
    }
} catch {
    Write-Log 'ERROR' "Ativacao OEM: $($_.Exception.Message)"
}

# Trocar senha de bootstrap da conta admin ($AdminAccount, criada pelo autounattend)
# pela senha real do config.ps1
try {
    $adminPass = ConvertTo-SecureString $AdminNewPass -AsPlainText -Force
    Set-LocalUser -Name $AdminAccount -Password $adminPass -ErrorAction Stop
    Write-Log 'OK' "Senha de $AdminAccount atualizada (bootstrap removida)"
} catch {
    Write-Log 'ERROR' "Trocar senha de ${AdminAccount}: $($_.Exception.Message)"
    # Falha aqui deixa a maquina com a senha BOOTSTRAP (a do autounattend). Tratar como
    # grave: alerta bloqueante no modo interativo + o erro ja entra no resumo final (exit 1).
    if (-not $Unattended) {
        [System.Windows.Forms.MessageBox]::Show(
            "FALHA AO TROCAR A SENHA DE $AdminAccount.`n`nA maquina esta com a senha BOOTSTRAP. " +
            "Troque manualmente ANTES de entregar (ex.: net user $AdminAccount *).`n`nErro: $($_.Exception.Message)",
            'Setup — RISCO DE SEGURANCA', 'OK', 'Error') | Out-Null
    }
}

# ============================================================
# FASE 2 — WiFi, share e dados iniciais
# ============================================================

# WiFi
if ($WifiSSID) { try {
    $escapedSSID = [System.Security.SecurityElement]::Escape($WifiSSID)
    $escapedPass = [System.Security.SecurityElement]::Escape($WifiPass)
    $wifiXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$escapedSSID</name>
  <SSIDConfig><SSID><name>$escapedSSID</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption>
      <authentication>WPA2PSK</authentication>
      <encryption>AES</encryption>
      <useOneX>false</useOneX>
    </authEncryption>
    <sharedKey>
      <keyType>passPhrase</keyType>
      <protected>false</protected>
      <keyMaterial>$escapedPass</keyMaterial>
    </sharedKey>
  </security></MSM>
</WLANProfile>
"@
    $wifiXmlPath = "$env:TEMP\corp_wifi_profile.xml"
    Set-Content -Path $wifiXmlPath -Value $wifiXml -Encoding UTF8
    netsh wlan add profile filename="$wifiXmlPath" 2>&1 | Out-Null
    # add profile grava o perfil de forma sincrona; o connect pode ser emitido direto.
    netsh wlan connect name="$WifiSSID" 2>&1 | Out-Null
    Write-Log 'OK' "WiFi $WifiSSID configurado"
} catch {
    Write-Log 'WARN' "WiFi: $($_.Exception.Message)"
} } else { Write-Log 'WARN' "WiFi ignorado (WifiSSID vazio)" }

# Mapear share
if ($SharePath) { try {
    New-SmbMapping -RemotePath $SharePath -UserName $ShareUser -Password $SharePass -Persistent $false -ErrorAction Stop | Out-Null
    Write-Log 'OK' "Share mapeado: $SharePath"
} catch {
    Write-Log 'WARN' "Share: $($_.Exception.Message)"
} } else { Write-Log 'WARN' "Share ignorado (SharePath vazio)" }

# Carregar printers.json do pendrive
$Printers = @()
$PrintersJson = Join-Path $ScriptDir 'printers.json'
if (Test-Path $PrintersJson) {
    try {
        $Printers = @(Get-Content $PrintersJson -Raw -Encoding UTF8 | ConvertFrom-Json)
        Write-Log 'OK' "$($Printers.Count) impressoras carregadas"
    } catch {
        Write-Log 'ERROR' "printers.json: $($_.Exception.Message)"
    }
} else {
    Write-Log 'WARN' "printers.json nao encontrado no pendrive"
}

# ============================================================
# Pre-GUI — dispara o Ninite cedo (overlap com a digitacao da GUI)
# ============================================================
# Ninite e' o instalador mais longo (baixa varios apps da internet). Lancado AQUI,
# baixa enquanto o tecnico preenche a GUI (tempo morto). A internet vem do WiFi
# (FASE 2, DHCP, ja no ar); independe do ethernet, que so e' configurado na FASE 4.
# A infra do pool (Start-BgInstall/$BgInstalls) e' definida aqui e reusada na FASE 5;
# o join de todos e' na FASE 7. Mutex MSI: Ninite e WebAgent nao se sobrepoem
# (WebAgent so roda na FASE 7, apos o pool).
$BgInstalls = [System.Collections.Generic.List[object]]::new()
function Start-BgInstall {
    param([string]$Name, [string]$FilePath, [string[]]$ArgumentList = @(), [int[]]$OkCodes = @(0))
    $params = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList.Count) { $params['ArgumentList'] = $ArgumentList }
    $proc = Start-Process @params
    $BgInstalls.Add([pscustomobject]@{ Name = $Name; Proc = $proc; OkCodes = $OkCodes })
    Write-Log 'INFO' "$Name iniciado em background (PID $($proc.Id))"
    return $proc
}

$NinitePath = Join-Path $ScriptDir 'ninite.exe'
if (Test-Path $NinitePath) {
    try { Start-BgInstall 'Ninite' $NinitePath | Out-Null }
    catch { Write-Log 'ERROR' "Ninite: $($_.Exception.Message)" }
} else {
    Write-Log 'WARN' "ninite.exe nao encontrado no pendrive"
}

# ============================================================
# FASE 3 — GUI
# ============================================================

if (-not $Unattended) {
try {

$Form = New-Object System.Windows.Forms.Form
$Form.Text            = 'Configuracao de Maquina Nova'
$Form.Size            = New-Object System.Drawing.Size(520, 660)
$Form.StartPosition   = 'CenterScreen'
$Form.FormBorderStyle = 'FixedDialog'
$Form.MaximizeBox     = $false
$Form.BackColor       = [System.Drawing.Color]::FromArgb(245, 246, 248)
$Form.ForeColor       = [System.Drawing.Color]::FromArgb(32, 32, 32)
$Form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

function Add-Label([System.Windows.Forms.Form]$f, [string]$text, [int]$x, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text     = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $true
    $f.Controls.Add($l)
}

function New-TextBox([int]$x, [int]$y, [int]$w = 480) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location    = New-Object System.Drawing.Point($x, $y)
    $t.Size        = New-Object System.Drawing.Size($w, 23)
    $t.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $t.BackColor   = [System.Drawing.Color]::White
    return $t
}

function New-Combo([int]$x, [int]$y, [int]$w = 480) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location      = New-Object System.Drawing.Point($x, $y)
    $c.Size          = New-Object System.Drawing.Size($w, 23)
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle     = [System.Windows.Forms.FlatStyle]::Flat
    $c.BackColor     = [System.Drawing.Color]::White
    return $c
}

$y = 12

Add-Label $Form 'Nome completo (do chamado):' 10 $y; $y += 20
$TxtFullName = New-TextBox 10 $y; $Form.Controls.Add($TxtFullName); $y += 35

Add-Label $Form 'Username (ex: joao.silva):' 10 $y; $y += 20
$TxtUsername = New-TextBox 10 $y; $Form.Controls.Add($TxtUsername); $y += 35

Add-Label $Form 'Dominio de email:' 10 $y; $y += 20
$CmbDomain = New-Combo 10 $y 300
$EmailDomains | ForEach-Object { $CmbDomain.Items.Add($_) | Out-Null }
$CmbDomain.SelectedIndex = 0
$Form.Controls.Add($CmbDomain); $y += 35

Add-Label $Form 'Configuracao de rede:' 10 $y; $y += 20
$RadioDhcp            = New-Object System.Windows.Forms.RadioButton
$RadioDhcp.Text       = 'DHCP (automatico)'
$RadioDhcp.Location   = New-Object System.Drawing.Point(10, $y)
$RadioDhcp.AutoSize   = $true
$RadioDhcp.Checked    = $true
$RadioStatic          = New-Object System.Windows.Forms.RadioButton
$RadioStatic.Text     = 'IP Estatico'
$RadioStatic.Location = New-Object System.Drawing.Point(190, $y)
$RadioStatic.AutoSize = $true
$Form.Controls.Add($RadioDhcp); $Form.Controls.Add($RadioStatic); $y += 30

$LblIp      = New-Object System.Windows.Forms.Label
$LblIp.Text = 'IP (ex: 10.0.X.X):'
$LblIp.Location = New-Object System.Drawing.Point(10, $y)
$LblIp.AutoSize = $true
$LblIp.Visible  = $false
$TxtIp          = New-TextBox 140 $y 160
$TxtIp.Visible  = $false
$Form.Controls.Add($LblIp); $Form.Controls.Add($TxtIp); $y += 35

$RadioStatic.Add_CheckedChanged({ $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked })
$RadioDhcp.Add_CheckedChanged({   $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked })

Add-Label $Form 'Impressora principal:' 10 $y; $y += 20
$CmbPrinter = New-Combo 10 $y
$CmbPrinter.Items.Add('(Nenhuma)') | Out-Null
foreach ($p in $Printers) { $CmbPrinter.Items.Add("$($p.name) — $($p.model) [$($p.ip)]") | Out-Null }
$CmbPrinter.SelectedIndex = 0
$Form.Controls.Add($CmbPrinter); $y += 35

Add-Label $Form 'Setor (para assinatura):' 10 $y; $y += 20
$CmbSector = New-Combo 10 $y
$Form.Controls.Add($CmbSector); $y += 35

Add-Label $Form 'Assinatura base (.htm):' 10 $y; $y += 20
$CmbSigTemplate = New-Combo 10 $y
$CmbSigTemplate.Items.Add('(Automatico — primeiro encontrado)') | Out-Null
$CmbSigTemplate.SelectedIndex = 0
$Form.Controls.Add($CmbSigTemplate); $y += 35

$ChkWebAgent          = New-Object System.Windows.Forms.CheckBox
$ChkWebAgent.Text     = 'Instalar WebAgent'
$ChkWebAgent.Location = New-Object System.Drawing.Point(10, $y)
$ChkWebAgent.AutoSize = $true
$Form.Controls.Add($ChkWebAgent); $y += 40

$BtnOk          = New-Object System.Windows.Forms.Button
$BtnOk.Text     = 'Iniciar Configuracao'
$BtnOk.Location = New-Object System.Drawing.Point(10, $y)
$BtnOk.Size     = New-Object System.Drawing.Size(480, 35)
$BtnOk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnOk.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$BtnOk.ForeColor = [System.Drawing.Color]::White
$BtnOk.FlatAppearance.BorderSize          = 0
$BtnOk.FlatAppearance.MouseOverBackColor  = [System.Drawing.Color]::FromArgb(0, 102, 184)
$BtnOk.FlatAppearance.MouseDownBackColor  = [System.Drawing.Color]::FromArgb(0, 90, 158)
$BtnOk.Cursor    = [System.Windows.Forms.Cursors]::Hand
$BtnOk.Add_Click({
    if (-not $TxtFullName.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show('Preencha o nome completo.', 'Setup', 'OK', 'Warning') | Out-Null; return
    }
    if (-not $TxtUsername.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show('Preencha o username.', 'Setup', 'OK', 'Warning') | Out-Null; return
    }
    if ($RadioStatic.Checked -and -not $TxtIp.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show('Preencha o IP estatico.', 'Setup', 'OK', 'Warning') | Out-Null; return
    }
    $Form.Tag = 'OK'
    $Form.Close()
})
$Form.Controls.Add($BtnOk)

# Evento: dominio muda → recarrega setores
$CmbDomain.Add_SelectedIndexChanged({
    if ($CmbDomain.SelectedIndex -lt 0) { return }
    $d  = $CmbDomain.SelectedItem.ToString()
    $dp = Join-Path $PathSignatures $d
    $CmbSector.Items.Clear()
    if (Test-Path $dp) {
        $dirs = @(Get-ChildItem -Path $dp -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        if ($dirs.Count -gt 0) { $dirs | ForEach-Object { $CmbSector.Items.Add($_) | Out-Null } }
        else { $CmbSector.Items.Add('(Sem setores)') | Out-Null }
    } else {
        $CmbSector.Items.Add('(Pasta nao encontrada)') | Out-Null
    }
    if ($CmbSector.Items.Count -gt 0) { $CmbSector.SelectedIndex = 0 }
})

# Evento: setor muda → recarrega .htm disponiveis
$CmbSector.Add_SelectedIndexChanged({
    if ($CmbSector.SelectedIndex -lt 0 -or -not $CmbDomain.SelectedItem) { return }
    $d = $CmbDomain.SelectedItem.ToString()
    $s = $CmbSector.SelectedItem.ToString()
    $CmbSigTemplate.Items.Clear()
    $CmbSigTemplate.Items.Add('(Automatico — primeiro encontrado)') | Out-Null
    if ($s -notmatch '^\(') {
        $sp = Join-Path (Join-Path $PathSignatures $d) $s
        if (Test-Path $sp) {
            Get-ChildItem -Path $sp -Filter '*.htm' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^[._]' } |
                ForEach-Object { $CmbSigTemplate.Items.Add($_.Name) | Out-Null }
        }
    }
    $CmbSigTemplate.SelectedIndex = 0
})

# Carga inicial: dispara evento de dominio para popular setores e templates
$CmbDomain.SelectedIndex = -1
$CmbDomain.SelectedIndex = 0

$Form.ShowDialog() | Out-Null

if ($Form.Tag -ne 'OK') {
    Write-Log 'WARN' "Setup cancelado"
    exit 0
}

$FullName        = $TxtFullName.Text.Trim()
$Username        = $TxtUsername.Text.Trim().ToLower()
$EmailDomain     = $CmbDomain.SelectedItem.ToString()
$Email           = "$Username@$EmailDomain"
$UseStatic       = $RadioStatic.Checked
$StaticIp        = if ($UseStatic) { $TxtIp.Text.Trim() } else { '' }
$PrinterIdx      = $CmbPrinter.SelectedIndex
$SelectedPrinter = if ($PrinterIdx -gt 0) { $Printers[$PrinterIdx - 1] } else { $null }
$SectorName      = $CmbSector.SelectedItem.ToString()
$SigTemplate     = $CmbSigTemplate.SelectedItem.ToString()
$InstallWebAgent = $ChkWebAgent.Checked

Write-Log 'INFO' "Nome=$FullName | User=$Username | Email=$Email"
Write-Log 'INFO' "Rede=$(if ($UseStatic) { "Estatico $StaticIp" } else { 'DHCP' })"
Write-Log 'INFO' "Impressora=$(if ($SelectedPrinter) { $SelectedPrinter.name } else { 'Nenhuma' })"
Write-Log 'INFO' "Setor=$SectorName | Template=$SigTemplate | WebAgent=$InstallWebAgent"

} catch {
    Write-Log 'FATAL' "Interface grafica falhou: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "Erro fatal na interface grafica:`n$($_.Exception.Message)",
        'Setup — Erro Fatal', 'OK', 'Error') | Out-Null
    exit 1
}

} else {
    $EmailDomain     = if ($TestDomain) { $TestDomain } else { $EmailDomains[0] }
    $FullName        = $TestFullName
    $Username        = $TestUsername.ToLower()
    $Email           = "$Username@$EmailDomain"
    $UseStatic       = $TestStaticIp.IsPresent
    $StaticIp        = if ($UseStatic) { $TestIpAddress } else { '' }
    $SelectedPrinter = if ($Printers.Count -gt 0) { $Printers[0] } else { $null }

    $sigDomainPath = Join-Path $PathSignatures $EmailDomain
    $SectorName    = if ($TestSector) {
        $TestSector
    } elseif (Test-Path $sigDomainPath) {
        (Get-ChildItem $sigDomainPath -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Name)
    } else { '' }

    $SigTemplate     = '(Automatico — primeiro encontrado)'
    $InstallWebAgent = $TestWebAgent.IsPresent

    Write-Log 'INFO' "Modo nao-interativo (Unattended)"
    Write-Log 'INFO' "Nome=$FullName | User=$Username | Email=$Email"
    Write-Log 'INFO' "Rede=$(if ($UseStatic) { "Estatico $StaticIp" } else { 'DHCP' })"
    Write-Log 'INFO' "Impressora=$(if ($SelectedPrinter) { $SelectedPrinter.name } else { 'Nenhuma' })"
    Write-Log 'INFO' "Setor=$SectorName | Template=$SigTemplate | WebAgent=$InstallWebAgent"
}

# ============================================================
# FASE 4 — Renomear PC + criar usuario + rede + wallpaper
# ============================================================

# Renomear PC para serial do BIOS
try {
    $sn = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber
    if ($sn -and $sn.Trim().Length -gt 0 -and $sn -notmatch 'O\.E\.M\.|Default|System Serial|To Be Filled') {
        $newName = $sn.Trim() -replace '[^A-Za-z0-9-]', ''
        if ($newName.Length -gt 15) { $newName = $newName.Substring(0, 15) }
        if ($env:COMPUTERNAME -eq $newName) {
            Write-Log 'OK' "PC ja nomeado como $newName"
        } else {
            Rename-Computer -NewName $newName -Force -ErrorAction Stop
            Write-Log 'OK' "PC renomeado para: $newName (efetivo no proximo reboot)"
        }
    } else {
        Write-Log 'WARN' "Serial invalido ou generico: '$sn' — renomear manualmente"
    }
} catch {
    Write-Log 'ERROR' "Renomear PC: $($_.Exception.Message)"
}

# Usuario local
try {
    $SecPass = ConvertTo-SecureString $UserInitialPass -AsPlainText -Force
    if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
        Write-Log 'OK' "Usuario ja existe: $Username"
    } else {
        New-LocalUser -Name $Username -Password $SecPass -FullName $FullName `
                      -Description 'Criado por setup.ps1' -PasswordNeverExpires:$true -ErrorAction Stop | Out-Null
        Write-Log 'OK' "Usuario criado: $Username"
    }

    # Grupo 'Users' por SID (S-1-5-32-545) — independe do locale (pt-BR 'Usuarios' vs en 'Users')
    try {
        $usersGroup = (Get-LocalGroup -SID 'S-1-5-32-545' -ErrorAction Stop).Name
        $isMember = @(Get-LocalGroupMember -Group $usersGroup -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*\$Username" -or $_.Name -eq $Username }).Count -gt 0
        if ($isMember) {
            Write-Log 'OK' "Usuario $Username ja esta no grupo $usersGroup"
        } else {
            Add-LocalGroupMember -Group $usersGroup -Member $Username -ErrorAction Stop
            Write-Log 'OK' "Usuario $Username adicionado ao grupo $usersGroup"
        }
    } catch {
        Write-Log 'ERROR' "Adicionar ao grupo de usuarios: $($_.Exception.Message)"
    }
} catch {
    Write-Log 'ERROR' "Criar usuario: $($_.Exception.Message)"
}

# Rede
try {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
               Select-Object -First 1
    if ($adapter) {
        if ($UseStatic -and $StaticIp) {
            $missNet = @('StaticPrefixLength', 'StaticGateway', 'DnsServers') |
                       Where-Object { -not (Get-Variable $_ -ValueOnly -ErrorAction SilentlyContinue) }
            if ($missNet) { throw "config.ps1 nao define para IP estatico: $($missNet -join ', ')" }
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $StaticIp `
                             -PrefixLength $StaticPrefixLength -DefaultGateway $StaticGateway -ErrorAction Stop | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
                                       -ServerAddresses $DnsServers -ErrorAction Stop | Out-Null
            Write-Log 'OK' "IP estatico: $StaticIp /$StaticPrefixLength GW $StaticGateway"
        } else {
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            Write-Log 'OK' "DHCP configurado"
        }
    }
} catch {
    Write-Log 'ERROR' "Rede: $($_.Exception.Message)"
}

# Wallpaper (so se config.ps1 definiu WallpaperFile — evita Join-Path com $null sob StrictMode)
$WallpaperSrc = if ($WallpaperFile) { Join-Path $ScriptDir $WallpaperFile } else { $null }
if ($WallpaperSrc -and (Test-Path $WallpaperSrc)) {
    try {
        $WallpaperDest = "$env:WINDIR\Web\Wallpaper\Corp"
        New-Item -ItemType Directory -Path $WallpaperDest -Force | Out-Null
        Copy-Item $WallpaperSrc "$WallpaperDest\wallpaper.jpg" -Force
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CorpWallpaper {
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
        [CorpWallpaper]::SystemParametersInfo(20, 0, "$WallpaperDest\wallpaper.jpg", 3) | Out-Null
        Write-Log 'OK' "Wallpaper aplicado"
    } catch {
        Write-Log 'ERROR' "Wallpaper: $($_.Exception.Message)"
    }
}

# ============================================================
# FASE 5 — Instalar programas (resto do pool, em paralelo)
# ============================================================
# Ninite ja foi lancado no pre-GUI (baixando durante a digitacao). Aqui entram os
# demais via Start-BgInstall (sem -Wait): Office (Click-to-Run, engine separada),
# Belarc e Epson (EXE /S). O join e' na FASE 7; a assinatura (FASE 6) roda sobreposta.
# WebAgent (MSI) so na FASE 7, apos o pool (mutex _MSIExecute / erro 1618).

# Office (pool) — Click-to-Run e' engine separada do msiexec, roda paralelo
try {
    $officeOdt   = Join-Path $PathOffice 'setup.exe'
    $officeLocal = Join-Path $ScriptDir 'OfficeSetup.exe'
    if (Test-Path $officeOdt) {
        $confXml = Join-Path $PathOffice 'configuration.xml'
        $oArgs = if (Test-Path $confXml) { @('/configure', $confXml) } else { @() }
        Start-BgInstall 'Office ODT' $officeOdt $oArgs | Out-Null
    } elseif (Test-Path $officeLocal) {
        Start-BgInstall 'Office Click-to-Run' $officeLocal | Out-Null
    } else {
        Write-Log 'WARN' "Instalador Office nao encontrado (share: $PathOffice | pendrive: $ScriptDir)"
    }
} catch { Write-Log 'ERROR' "Office: $($_.Exception.Message)" }

# Belarc (pool) — EXE /S
try {
    $belarc = Get-ChildItem -Path $PathBelarc -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($belarc) { Start-BgInstall 'Belarc' $belarc.FullName @('/S') | Out-Null }
    else { Write-Log 'WARN' "Instalador Belarc nao encontrado em $PathBelarc" }
} catch { Write-Log 'ERROR' "Belarc: $($_.Exception.Message)" }

# Epson driver (pool) + porta TCP/IP. A impressora e' adicionada na FASE 7, depois
# do driver registrar (o join garante que o instalador saiu). A porta nao depende do
# driver, entao ja e' criada aqui.
$script:PrinterPort = $null
if ($SelectedPrinter) {
    try {
        $epson = Get-ChildItem -Path $PathEpson -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($epson) { Start-BgInstall 'Driver Epson' $epson.FullName @('/S') | Out-Null }
        else { Write-Log 'WARN' "Instalador Epson nao encontrado em $PathEpson" }
        $script:PrinterPort = "IP_$($SelectedPrinter.ip)"
        Add-PrinterPort -Name $script:PrinterPort -PrinterHostAddress $SelectedPrinter.ip -ErrorAction SilentlyContinue
    } catch { Write-Log 'ERROR' "Impressora (preparo): $($_.Exception.Message)" }
}

# WebAgent roda na FASE 7 — e' msiexec, espera o pool (Ninite) p/ nao colidir no mutex.

# ============================================================
# FASE 6 — Assinatura Outlook
# ============================================================

if ($SectorName -and $SectorName -notmatch '^\(') {
    try {
        $sectorPath = Join-Path (Join-Path $PathSignatures $EmailDomain) $SectorName

        if ($SigTemplate -eq '(Automatico — primeiro encontrado)') {
            $srcFile = Get-ChildItem -Path $sectorPath -Filter '*.htm' -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notmatch '^[._]' } | Select-Object -First 1
        } else {
            $srcFile = Get-Item -Path (Join-Path $sectorPath $SigTemplate) -ErrorAction SilentlyContinue
        }

        if ($srcFile) {
            $content = [System.IO.File]::ReadAllText($srcFile.FullName, [System.Text.Encoding]::UTF8)

            # Detecta email antigo
            $emailMatch = [regex]::Match($content, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')
            $oldEmail   = if ($emailMatch.Success) { $emailMatch.Value } else { '' }

            # Detecta nome antigo no span bold
            $nameMatch  = [regex]::Match($content, 'font-weight:\s*bold[^>]*>([^<]+)')
            $oldName    = if ($nameMatch.Success) { $nameMatch.Groups[1].Value.Trim() } else { '' }

            $newContent = $content
            if ($oldEmail) { $newContent = $newContent -replace [regex]::Escape($oldEmail), $Email }
            if ($oldName)  { $newContent = $newContent -replace [regex]::Escape($oldName),  $FullName }

            $sigFolder = "$env:APPDATA\Microsoft\Signatures"
            New-Item -ItemType Directory -Path $sigFolder -Force | Out-Null
            [System.IO.File]::WriteAllText("$sigFolder\$Username.htm", $newContent, [System.Text.Encoding]::UTF8)

            Write-Log 'OK' "Assinatura criada: $sigFolder\$Username.htm"
            Write-Log 'INFO' "Base: $($srcFile.Name) | '$oldName' -> '$FullName' | '$oldEmail' -> '$Email'"
        } else {
            Write-Log 'WARN' "Nenhum .htm encontrado em: $sectorPath"
        }
    } catch { Write-Log 'ERROR' "Assinatura: $($_.Exception.Message)" }
} else {
    Write-Log 'INFO' "Assinatura ignorada"
}

# ============================================================
# FASE 7 — Join dos instaladores + passos dependentes + checklist
# ============================================================

# Join: espera cada instalador do pool terminar e avalia o exit code.
foreach ($bgItem in $BgInstalls) {
    try {
        $bgItem.Proc.WaitForExit()
        Write-ProcResult $bgItem.Name $bgItem.Proc $bgItem.OkCodes
    } catch { Write-Log 'ERROR' "$($bgItem.Name) (join): $($_.Exception.Message)" }
}

# Impressora: o driver Epson ja terminou (join acima). Poll curto pelo registro do
# driver (pode atrasar segundos apos o instalador sair) e adiciona a impressora.
if ($SelectedPrinter -and $script:PrinterPort) {
    try {
        $driverName = $null
        for ($d = 0; $d -lt 30 -and -not $driverName; $d++) {
            $driverObj = Get-PrinterDriver -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match 'Epson' } | Select-Object -First 1
            if ($driverObj) { $driverName = $driverObj.Name } else { Start-Sleep -Milliseconds 500 }
        }
        if ($driverName) {
            Add-Printer -Name $SelectedPrinter.name -DriverName $driverName `
                        -PortName $script:PrinterPort -ErrorAction Stop | Out-Null
            Write-Log 'OK' "Impressora: $($SelectedPrinter.name) [$($SelectedPrinter.ip)]"
        } else {
            Write-Log 'WARN' "Driver Epson nao localizado — adicionar impressora manualmente"
        }
    } catch { Write-Log 'ERROR' "Impressora: $($_.Exception.Message)" }
}

# WebAgent (msiexec) — agora o pool/Ninite terminou, o mutex do Installer esta livre.
# Tenta MSI > ZIP (extrai MSI) > EXE legacy.
if ($InstallWebAgent) {
    try {
        $waMsi = Get-ChildItem -Path $PathWebAgent -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
        $waZip = Get-ChildItem -Path $PathWebAgent -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
        $waExe = Get-ChildItem -Path $PathWebAgent -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($waMsi) {
            Write-Log 'INFO' "WebAgent MSI: $($waMsi.Name)"
            $p = Start-Process -FilePath 'msiexec.exe' `
                 -ArgumentList '/i', "`"$($waMsi.FullName)`"", '/quiet', '/norestart' -Wait -PassThru
            Write-ProcResult 'WebAgent (MSI)' $p @(0, 3010)
        } elseif ($waZip) {
            Write-Log 'INFO' "WebAgent ZIP: $($waZip.Name) — extraindo..."
            $extractDir = "$env:TEMP\webagent_extract"
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            Expand-Archive -Path $waZip.FullName -DestinationPath $extractDir -Force
            $msiInZip = Get-ChildItem -Path $extractDir -Filter '*.msi' -Recurse | Select-Object -First 1
            if ($msiInZip) {
                $p = Start-Process -FilePath 'msiexec.exe' `
                     -ArgumentList '/i', "`"$($msiInZip.FullName)`"", '/quiet', '/norestart' -Wait -PassThru
                Write-ProcResult 'WebAgent (ZIP)' $p @(0, 3010)
            } else {
                Write-Log 'WARN' "MSI nao encontrado dentro do ZIP"
            }
        } elseif ($waExe) {
            Write-Log 'INFO' "WebAgent EXE (legacy): $($waExe.Name)"
            $p = Start-Process -FilePath $waExe.FullName -ArgumentList '/S' -Wait -PassThru
            Write-ProcResult 'WebAgent (EXE)' $p
        } else {
            Write-Log 'WARN' "Instalador WebAgent nao encontrado em $PathWebAgent"
        }
    } catch { Write-Log 'ERROR' "WebAgent: $($_.Exception.Message)" }
}

$checklist = @"

========================================
  CHECKLIST MANUAL POS-SETUP
========================================
Usuario  : $Username ($FullName)
Email    : $Email
Data     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
PC nome  : $env:COMPUTERNAME

PENDENCIAS:
[ ] REBOOT para aplicar novo nome do PC
[ ] Registrar maquina na intranet
[ ] Login Office 365: $Email
[ ] Verificar assinatura no Outlook
[ ] Testar impressora: $(if ($SelectedPrinter) { "$($SelectedPrinter.name) [$($SelectedPrinter.ip)]" } else { 'Nenhuma' })
[ ] TOTVS (se solicitado no ticket)
[ ] Entregar credenciais: login=$Username / senha=(ver config.ps1 — nao registrar em log)
========================================
Log: $LogFile
"@

Add-Content -Path $LogFile -Value $checklist -Encoding UTF8 -ErrorAction SilentlyContinue

# MessageBox e modal e BLOQUEIA — so mostra no modo interativo. No -Unattended
# (hands-free via autounattend) o popup travaria o fluxo, entao some.
if (-not $Unattended) {
    [System.Windows.Forms.MessageBox]::Show(
        $checklist,
        'Setup — Concluido',
        'OK',
        'Information'
    ) | Out-Null
}

if ($script:Erros.Count -gt 0) {
    $s = if ($script:Erros.Count -ne 1) { 's' } else { '' }
    $errSummary = "ATENCAO: $($script:Erros.Count) erro$s durante o setup:`n`n" +
                  ($script:Erros -join "`n") +
                  "`n`nLog completo: $LogFile"
    Write-Log 'INFO' "Setup concluido com $($script:Erros.Count) erro$s"
    if (-not $Unattended) {
        [System.Windows.Forms.MessageBox]::Show(
            $errSummary,
            'Setup — Erros Encontrados',
            'OK',
            'Warning'
        ) | Out-Null
    }
    # Sinaliza falha ao chamador (run.bat / FirstLogonCommands checam %errorlevel%).
    exit 1
} else {
    Write-Log 'OK' "setup.ps1 concluido sem erros"
    exit 0
}
