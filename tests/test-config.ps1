# ============================================================
# test-config.ps1 — FAKE configuration for Sandbox testing
# Replaces the real config.ps1 (fake credentials, no risk)
# ============================================================

# --- Local credentials (fake) ---
# Sandbox interactive-GUI note: setup.ps1's context guard requires the current user to equal
# $AdminAccount (production runs as the bootstrap admin via AutoLogon). Windows Sandbox always
# logs in as WDAGUtilityAccount, so point the bootstrap-admin name at it here — the guard then
# passes and setup.ps1 rotates THIS throwaway account's password. Production config.ps1 (built by
# build.bat) uses the real bootstrap admin name. The -Headless / -PhaseB paths pass -Unattended and
# skip the guard, so this value does not affect them.
$AdminAccount    = 'WDAGUtilityAccount'
$AdminNewPass    = "Test@Sandbox2024!"
$UserInitialPass = "Test@Sandbox2024!"

# --- Domains available in the form ---
$EmailDomains = @('example.com.br')

# --- Static IP ---
$StaticGateway      = "192.168.1.1"
$StaticPrefixLength = 24
$DnsServers         = @('8.8.8.8', '8.8.4.4')

# --- Wallpaper (default + per-domain override) ---
# The map keys example.com.br to a second file so the Sandbox -TestDomain example.com.br exercises
# the domain-override branch (staging copies wallpaper-alt.jpg, not the default).
$WallpaperFile     = 'wallpaper.jpg'
$WallpaperByDomain = @{ 'example.com.br' = 'wallpaper-alt.jpg' }

# --- Corp browser bookmarks (fake links; exercise the two-checkbox + seeding path) ---
$Bookmarks = @(
    @{ Name = 'Intranet'; Url = 'https://10.0.0.1/portal' },
    @{ Name = 'WebApp';   Url = 'https://10.0.0.1:1234/webapp/' }
)

# Exercise the desktop-shortcut path in the -PhaseB smoke: WebApp gets a .url on the desktop.
$DesktopShortcutBookmarks = @('WebApp')

# --- WiFi (does not exist in the Sandbox — setup.ps1 will log WARN and continue) ---
$WifiSSID = "SandboxTestNetwork"
$WifiPass = "FakeWifiPass@2024!"

# --- Paths (relative to $ScriptDir = simulated USB root) ---
# $ScriptDir is set by setup.ps1 before dot-sourcing this file
$PathOffice     = "$ScriptDir\Office"
$PathBelarc     = $ScriptDir
$PathEpson      = "$ScriptDir\Drivers Epson"
$PathWebAgent   = "$ScriptDir\WebAgent\windows"
$PathSignatures = "$ScriptDir\signatures-2026"
