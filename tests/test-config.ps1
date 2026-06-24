# ============================================================
# test-config.ps1 — Configuração FAKE para testes no Sandbox
# Substitui o config.ps1 real (credenciais falsas, sem risco)
# ============================================================

# --- Credenciais locais (falsas) ---
$AdminAccount    = 'setupadmin'
$AdminNewPass    = "Teste@Sandbox2024!"
$UserInitialPass = "Teste@Sandbox2024!"

# --- Domínios disponíveis no formulário ---
$EmailDomains = @('empresa.com.br')

# --- Share (não existe — setup.ps1 vai logar WARN e continuar) ---
$SharePath   = ""
$ShareUser   = ""
$SharePass   = ""

# --- IP estático ---
$StaticGateway      = "192.168.1.1"
$StaticPrefixLength = 24
$DnsServers         = @('8.8.8.8', '8.8.4.4')

# --- Wallpaper ---
$WallpaperFile = 'wallpaper.jpg'

# --- WiFi (não existe no Sandbox — setup.ps1 vai logar WARN e continuar) ---
$WifiSSID = "RedeTesteSandbox"
$WifiPass = "SenhaWifiFake@2024!"

# --- Paths (relativos ao $ScriptDir = raiz do USB simulado) ---
# $ScriptDir é definido pelo setup.ps1 antes de dot-source este arquivo
$PathOffice     = "$ScriptDir\Office"
$PathBelarc     = $ScriptDir
$PathEpson      = "$ScriptDir\Drivers Epson"
$PathWebAgent   = "$ScriptDir\20.WebAgent\windows"
$PathSignatures = "$ScriptDir\assinatura-2026"
