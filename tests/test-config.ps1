# ============================================================
# test-config.ps1 — FAKE configuration for Sandbox testing
# Replaces the real config.ps1 (fake credentials, no risk)
# ============================================================

# --- Local credentials (fake) ---
$AdminAccount    = 'setupadmin'
$AdminNewPass    = "Test@Sandbox2024!"
$UserInitialPass = "Test@Sandbox2024!"

# --- Domains available in the form ---
$EmailDomains = @('empresa.com.br')

# --- Share (does not exist — setup.ps1 will log WARN and continue) ---
$SharePath   = ""
$ShareUser   = ""
$SharePass   = ""

# --- Static IP ---
$StaticGateway      = "192.168.1.1"
$StaticPrefixLength = 24
$DnsServers         = @('8.8.8.8', '8.8.4.4')

# --- Wallpaper ---
$WallpaperFile = 'wallpaper.jpg'

# --- WiFi (does not exist in the Sandbox — setup.ps1 will log WARN and continue) ---
$WifiSSID = "SandboxTestNetwork"
$WifiPass = "FakeWifiPass@2024!"

# --- Paths (relative to $ScriptDir = simulated USB root) ---
# $ScriptDir is set by setup.ps1 before dot-sourcing this file
$PathOffice     = "$ScriptDir\Office"
$PathBelarc     = $ScriptDir
$PathEpson      = "$ScriptDir\Drivers Epson"
$PathWebAgent   = "$ScriptDir\20.WebAgent\windows"
$PathSignatures = "$ScriptDir\assinatura-2026"
