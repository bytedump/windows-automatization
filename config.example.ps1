# ============================================================
# config.example.ps1 — Template de configuração
# COPIE para config.ps1 e preencha os valores reais
# config.ps1 está no .gitignore — NUNCA commitar
# ============================================================

# --- Credenciais de administração local ---
$AdminAccount    = "setupadmin"                   # nome da conta admin bootstrap; DEVE bater com o que o build-usb.ps1 grava no autounattend
$AdminNewPass    = "SENHA_ADMIN_REAL"             # substitui a senha de bootstrap do autounattend (gerado pelo build-usb.ps1)
$UserInitialPass = "SENHA_INICIAL_USUARIO"        # senha provisória dos usuários criados (devem trocar no 1o login)

# --- Domínios de email (dropdown da GUI) ---
$EmailDomains = @('empresa.com.br', 'empresa.org.br')  # adicione/remova conforme necessário

# --- Rede corporativa (share) ---
$SharePath   = "\\SERVIDOR\PASTA"               # ex: \\10.0.1.1\grupo.tecnologia
$ShareUser   = "USUARIO"                         # ex: usuario_share
$SharePass   = "SENHA"                           # senha de acesso ao share

# --- IP estático (usado quando técnico escolhe "IP Estático" na GUI) ---
$StaticGateway      = "GATEWAY"                  # ex: 192.168.1.1
$StaticPrefixLength = 24                         # máscara: 24=/24 · 22=/22 · 16=/16
$DnsServers         = @('8.8.8.8', '8.8.4.4')   # DNS primário e secundário

# --- Wallpaper (nome do arquivo na raiz do pendrive) ---
$WallpaperFile = 'wallpaper.jpg'      # nome do arquivo de wallpaper na raiz do pendrive

# --- WiFi corporativo ---
$WifiSSID    = "NOME_DA_REDE"
$WifiPass    = "SENHA_WIFI"

# --- Paths — tudo no pendrive ($ScriptDir = raiz do pendrive, definido pelo setup.ps1) ---
$PathOffice     = "$ScriptDir\Office"               # ODT; se ausente usa OfficeSetup.exe na raiz
$PathBelarc     = $ScriptDir                        # belarc.exe na raiz do pendrive
$PathEpson      = "$ScriptDir\Drivers Epson"        # pasta com drivers .exe
$PathWebAgent   = "$ScriptDir\20.WebAgent\windows"  # pasta com .msi do WebAgent
$PathSignatures = "$ScriptDir\assinatura-2026"      # estrutura: \{dominio}\{setor}\usuario.htm

# --- Impressoras ---
# printers.json fica na raiz do pendrive junto com setup.ps1
# Formato: [{"name":"...","model":"...","ip":"..."}]
