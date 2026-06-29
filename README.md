# 🖥️ Windows 11 — Automated Provisioning

[![CI](https://github.com/bytedump/windows-automatization/actions/workflows/ci.yml/badge.svg)](https://github.com/bytedump/windows-automatization/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat&logo=powershell&logoColor=white)
![Windows 11](https://img.shields.io/badge/Windows%2011-0078D6?style=flat&logo=windows&logoColor=white)
![autounattend.xml](https://img.shields.io/badge/autounattend.xml-1e2327?style=flat)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

Hands-free provisioning of Windows 11 machines from a USB drive: an `autounattend.xml`
answer file installs Windows with zero clicks, then a post-install PowerShell script
(`setup.ps1`) configures the machine through a small GUI — user, network, printer, apps
and Outlook signature.

No secrets live in this repository. Credentials and real data stay on the USB drive
(`config.ps1`, the generated `autounattend.xml`, `printers.json`) — all gitignored. The
repo ships **templates**; you fill them in once when you build the master USB.

## 📸 Preview

> _PowerShell setup GUI — screenshot coming soon._
<!-- ![Setup GUI](docs/setup-gui.png) -->

## 📑 Table of Contents

- [Overview](#-overview)
- [Preparing the master USB](#-preparing-the-master-usb)
- [USB drive layout](#-usb-drive-layout)
- [Security model](#-security-model)
- [1. autounattend.xml](#-1-autounattendxml)
- [2. setup.ps1](#-2-setupps1)
- [3. Full flow](#-3-full-flow)
- [4. How to test](#-4-how-to-test)
- [Troubleshooting](#-troubleshooting)
- [5. Repository files](#-5-repository-files)
- [Roadmap — intranet auto-provisioning](#-roadmap--intranet-auto-provisioning-planned)
- [License](#-license)

## 📋 Overview

- 100% hands-free installation (zero clicks until the desktop)
- Secrets kept **out of the repository** — templates in git, real values on the USB drive
- Post-install script with an interactive GUI: user, network, printer, apps, Outlook signature
- Programs and signatures shipped on the USB drive — no network share needed for installation
- Installers run **in parallel** to cut wall-clock time

---

## 🛠️ Preparing the master USB

Done **once** per master USB. The per-machine boot afterwards is fully hands-free.

### Burning the boot USB (Rufus)

The USB must first be a **bootable Windows 11 installer**. Burn the ISO with
[Rufus](https://rufus.ie) (GPT / UEFI), then copy the repo payload onto its root. Two
things matter:

> **Use an ISO whose language matches the answer file (pt-BR).** `autounattend.xml` requests
> `UILanguage = pt-BR`; an **English (en-US) ISO does not ship the pt-BR language pack** in
> `boot.wim`, so Setup cannot apply it and **stops on the language/keyboard screen** for a
> manual pick. Download the **Windows 11 Portuguese (Brazil)** multi-edition ISO from Microsoft.

> **Leave every box unchecked in Rufus's "Customize Windows installation experience" /
> "Windows User Experience" dialog.** Ticking any of them makes Rufus write its **own**
> `autounattend.xml` to the USB root, which sits higher in Setup's search order and
> **overrides ours**. Our `autounattend.xml` already handles the TPM/Secure Boot/RAM bypass
> (via `LabConfig`) and the local account, so no Rufus customization is needed.

Copy the repo payload **after** Rufus finishes (the steps below write to the USB root).

1. **Copy the repo files** to the USB root (or a staging folder you copy to the USB).
2. **Generate `autounattend.xml`** from the template — this bakes in the bootstrap admin
   account name and password (the only place they exist; the file is gitignored):
   ```powershell
   .\build-usb.ps1 -OutPath E:\autounattend.xml   # E: = the USB root
   # prompts for the admin account name + password (hidden)
   ```
   Double-clicking `build-usb.ps1` flashes a window and closes (Windows opens `.ps1`
   in Notepad or runs it and exits before you can read it). Instead **double-click
   `build.bat`** — it runs the script with the execution policy bypassed and stays open
   so you can read the prompts and reminders. `autounattend.xml` is written next to it
   (run it from the USB root and the file lands there).
3. **Create `config.ps1`** from the template and fill in real values. `$AdminAccount`
   **must** match the account name you typed in step 2:
   ```powershell
   Copy-Item config.example.ps1 E:\config.ps1
   # then edit E:\config.ps1
   ```
4. **Create `printers.json`** from `printers.example.json` with your real printers.
5. **Add the binaries / assets** the installers expect (see [USB layout](#-usb-drive-layout)):
   `ninite.exe`, the `Office/` ODT folder (see [Office (ODT)](#office-odt)), `belarc.exe`,
   `Drivers Epson/`, `20.WebAgent/`, the wallpaper, the `assinatura-2026/` signature templates,
   and (optional) the `automatizacaoCloud/` HBR Cloud toolkit.
6. Plug the USB into the target machine and boot from it — the rest is automatic.

> The bootstrap password you set in step 2 is temporary: `setup.ps1` replaces it on first
> login with `$AdminNewPass` from `config.ps1`. Keep it different from any real password.

---

## 💾 USB drive layout

```
USB Root/
  ├── autounattend.xml          ← GENERATED by build-usb.ps1 (gitignored — has the bootstrap password)
  ├── setup.ps1                 ← Post-installation script (GUI) — Phase A
  ├── phase-b.ps1               ← Phase B (new user session): wallpaper, signature, default printer
  ├── cleanup.ps1               ← Cleanup (SYSTEM): zero AutoLogon, unregister tasks, delete staging
  ├── run.bat                   ← Manual fallback to re-run setup.ps1
  ├── build.bat                 ← Double-click launcher for build-usb.ps1 (ExecutionPolicy Bypass)
  ├── guard-disk.cmd            ← fail-closed disk guard (proceeds only if exactly 1 disk), run from autounattend in WinPE
  ├── config.ps1                ← Credentials and paths (copy from config.example.ps1 — gitignored)
  ├── printers.json             ← Printer list (copy from printers.example.json — gitignored)
  ├── belarc.exe                ← Belarc Advisor installer
  ├── Office/                   ← Office Deployment Tool (ODT) — see "Office (ODT)" below
  │     ├── setup.exe           ←   ODT bootstrapper (download at aka.ms/ODT)
  │     ├── configuration.xml   ←   copy from configuration.example.xml (gitignored)
  │     └── Office/Data/        ←   pre-downloaded bits (setup.exe /download — offline mode)
  ├── ninite.exe                ← Download at ninite.com (not committed)
  ├── wallpaper.jpg             ← Wallpaper (filename set in config.ps1 via $WallpaperFile)
  ├── Drivers Epson/            ← Epson driver executables
  ├── 20.WebAgent/windows/      ← WebAgent .msi installer
  ├── automatizacaoCloud/       ← HBR Cloud toolkit (optional): Instalar_HBR.bat + .ps1, HBRCloud.exe, HBRUpdater.exe, MySql.Data.dll
  └── assinatura-2026/          ← Outlook signature templates (gitignored)
        └── {domain}/
              └── {Sector}/
                    └── user.htm
```

---

## 🔒 Security model

No secret is committed. The repository holds templates; the real values are created on
the USB drive at build time and are all gitignored.

| Item | Where it lives |
|---|---|
| Bootstrap admin password | Only in the **generated** `autounattend.xml` (gitignored), created by `build-usb.ps1`. Replaced on first login by `setup.ps1`, which then **deletes** `autounattend.xml` from the USB and the `Panther\unattend.xml` copy. |
| Phase B handoff AutoLogon | `setup.ps1` writes the new user's password to `HKLM\…\Winlogon` in **plaintext for one boot** to autologon into Phase B. `AutoLogonCount=1` makes Windows consume + clear it even if cleanup never runs; `cleanup.ps1` (SYSTEM) zeroes **and verifies** it at the end of Phase B. `state.json` never holds a credential. |
| Real admin / user passwords | Only in `config.ps1` (gitignored) — `$AdminNewPass`, `$UserInitialPass`. ⚠️ `$AdminNewPass` is typically **reused fleet-wide** (the same local-admin password on every provisioned machine): a leak on one machine affects all of them, and rotating it means updating `config.ps1` and re-running setup everywhere. |
| Share / WiFi credentials | Only in `config.ps1` (gitignored) |
| Printer IPs / sectors | Only in `printers.json` (gitignored) — internal network data |
| Outlook signatures | Only in `assinatura-2026/` (gitignored) — employee personal data |
| WiFi profile | SSID and password XML-escaped via `SecurityElement.Escape`; the temp profile XML (plaintext PSK) is **deleted** right after `netsh` imports it |
| Share connection | `New-SmbMapping` — password never exposed on the command line or Event 4688 |
| Setup log | Credentials never written to `win11_setup_log.txt` |

> **Physical security of the USB.** Until `setup.ps1` finishes its first run, the USB carries
> live credentials in cleartext: the real passwords in `config.ps1` and the bootstrap password
> in `autounattend.xml`. The bootstrap password is **base64-encoded, not encrypted** — base64 is
> trivially reversible, so anyone holding the USB can decode it. Treat the prepared USB as a secret:
> keep it in locked storage, never leave it in public machines, and store it on an **encrypted
> volume — use BitLocker To Go** (*This PC → right-click the USB → Turn on BitLocker*) or an
> equivalent such as VeraCrypt. `setup.ps1` scrubs `autounattend.xml` after rotating the password,
> but `config.ps1` stays on the USB by design (so the operator can re-run setup).

### Why a bootstrap password at all

`autounattend.xml` cannot read external files — it is static XML processed by Windows
Setup (WinPE). The admin account must be created with a known password so AutoLogon can
fire and launch `setup.ps1`. That password is **bootstrap only**: `setup.ps1` rotates it
to `$AdminNewPass` from `config.ps1` on first login (and raises a blocking alert if the
rotation fails, so a machine is never silently left on the bootstrap password).

`build-usb.ps1` encodes it the way Windows expects — base64 of UTF-16 of
`password + "Password"` — into the LocalAccount and AutoLogon `<Value>` fields.

### Two-phase handoff (Phase A → reboot → Phase B + cleanup)

Provisioning splits into two phases so the per-user work runs in the **new user's own session**
(no impersonation) while machine setup keeps admin rights:

- **Phase A** — `setup.ps1`, elevated, as the bootstrap admin. Does all machine work (OEM license,
  rotate the bootstrap password, create the standard user, network, installs, machine-wide printer,
  stage the wallpaper). At the end it stages the handoff into `C:\ProgramData\CorpSetup`
  (`state.json` + copies of `phase-b.ps1`/`cleanup.ps1` + the signature subtree), registers two
  scheduled tasks (`CorpSetup-PhaseB-User`, `CorpSetup-PhaseB-System`), **arms a one-shot AutoLogon
  for the new user** and **reboots**.
- **Phase B** — `phase-b.ps1`, as the **new standard user** after the reboot+AutoLogon. Per-user
  only: wallpaper (HKCU), Outlook signature in `%APPDATA%` set as default New+Reply, default
  printer. Drops a `user-done` flag.
- **Cleanup** — `cleanup.ps1`, as **SYSTEM**. Waits for `user-done`, then **zeroes + verifies** the
  plaintext AutoLogon in `HKLM\…\Winlogon`, unregisters both tasks, and deletes the staging folder.
  It does **not** disable the bootstrap admin (no AD ⇒ it is the only local admin, kept for support).

`state.json` carries **no credential**. The only secret in flight is the one-boot plaintext AutoLogon
password (declared trade-off — Winlogon AutoLogon has no DPAPI option), self-clearing via
`AutoLogonCount=1` and zeroed by cleanup. The flow is gated by `-EnableHandoff` (passed from
`autounattend.xml`); the test harness never passes it, so the sandbox never reboots.

---

## 🧩 1. autounattend.xml

### What it does
Windows Setup answer file (generated from `autounattend.template.xml`). Boot from the USB
drive — installation runs without any interaction up to the desktop, then `setup.ps1`
opens automatically via `FirstLogonCommands`.

> **Single-disk assumption.** `DiskConfiguration` wipes `DiskID=0` with `WillWipeDisk=true`.
> Disk 0 is not deterministic across firmware, so wiping it is only safe on machines with a
> **single** fixed disk. The `guard-disk.cmd` wiring (below) is the fail-closed safeguard — it
> aborts the install unless it confirms exactly one disk.

### Settings

| Parameter | Value |
|---|---|
| Edition | Windows 11 Pro |
| Language / UI | pt-BR |
| Keyboard | ABNT2 (`0416:00010416`) |
| Time zone | E. South America Standard Time (Brasília) |
| Local admin account | `$AdminAccount` (bootstrap password — replaced by `setup.ps1`) |
| AutoLogon | Bootstrap admin, one-shot for Phase A (`LogonCount=1`); Phase A then arms a separate one-shot for the new user → Phase B |
| Auto-launch | `FirstLogonCommands` finds the USB (drive with `setup.ps1` **and** `config.ps1`), retries ~60s, opens `setup.ps1` (GUI) with `-EnableHandoff` (two-phase flow) |

> **Region/locale is hardcoded to pt-BR** (language, ABNT2 keyboard, Brasília time zone). The
> tool targets Brazilian deployments; using it elsewhere installs a pt-BR system. To retarget,
> change `InputLocale`/`SystemLocale`/`UILanguage`/`UserLocale` (all three passes) and `TimeZone`
> in `autounattend.template.xml`.

### Skipped screens (OOBE)

| Screen | Mechanism |
|---|---|
| Language / Region / Keyboard | `SetupUILanguage`, `InputLocale` — **only with a matching-language ISO (pt-BR)**; on 24H2/25H2 the new "ConX" setup may still show them. See [Troubleshooting](#-troubleshooting). |
| Product key | Generic Pro key `VK7JG-NPHTM-C97JM-9MPGT-3V66T` (selects edition, does not activate) |
| EULA | `<AcceptEula>true</AcceptEula>` |
| Disk / partition | `DiskConfiguration` with `WillWipeDisk=true` |
| Wi-Fi OOBE | `HideWirelessSetupInOOBE=true` |
| Microsoft account | `HideOnlineAccountScreens=true` |
| Local account OOBE | `HideLocalAccountScreen=true` + `UserAccounts` |
| Privacy | `ProtectYourPC=3` |
| Personalization | `SkipUserOOBE=true` |
| Network | `BypassNRO=1` (valid up to ~24H2; redundant here since the full OOBE is already skipped) |

### Partition scheme (GPT/UEFI)

| # | Type | Size | Format | Label |
|---|---|---|---|---|
| 1 | EFI | 300 MB | FAT32 | System |
| 2 | MSR | 16 MB | — | — |
| 3 | Primary | Remaining | NTFS | Windows (C:) |
| WinRE | Recovery | ~500 MB | NTFS | Created automatically **after** partition 3 |

> Recovery must come **after** the Windows partition — placing it before causes Setup to fail at ~50-60%.

### Compatibility — PCs without TPM 2.0

Automatic bypass via `LabConfig` keys in the `windowsPE` pass. Only these three exist;
`BypassCPUCheck` / `BypassStorageCheck` are no-ops.

| Key | Function |
|---|---|
| `BypassTPMCheck` | Skips TPM 2.0 requirement |
| `BypassSecureBootCheck` | Skips Secure Boot |
| `BypassRAMCheck` | Skips RAM check |

### Disk guard (fail-closed: exactly 1 disk)

`guard-disk.cmd` counts **fixed** disks in WinPE and is **fail-closed**: it lets the install
proceed **only** when it confirms *exactly one* fixed disk. On any other outcome — `0` disks
parsed, more than one disk, or a tooling error — it runs `wpeutil shutdown` **before** anything
is wiped. Counting only `MediaType='Fixed hard disk media'` excludes the boot USB itself (a
*removable* disk) and optical media, so the "exactly 1" check is never tripped by the install
medium.

WMIC is the primary counter (locale-independent, and it carries the fixed-media filter). The
Win11 25H2 Setup boot image ships WMIC but **not** `findstr` and **not** PowerShell — an earlier
`findstr`-based version counted `0` on every machine and aborted every install (caught in VM
testing). If WMIC is ever absent, the fallback counts disks via `diskpart` + `find`, covering
EN/pt/es/it/fr/de WinPE languages.

It is wired into `autounattend.xml` as two `RunSynchronous` commands in the
`Microsoft-Windows-Setup` component, **before** `DiskConfiguration`:

1. **Order 1** — the WinPE drive letter is not fixed, so it scans drives for `guard-disk.cmd`
   and calls it. On the "exactly 1" success path the script writes a marker
   (`%TEMP%\guard_ok.flag`).
2. **Order 2** — `if not exist %TEMP%\guard_ok.flag wpeutil shutdown`. This catches the case
   where `guard-disk.cmd` is **missing from the media** (so Order 1 never ran): no marker → the
   install still fails closed instead of wiping blind.

> ⚠️ The ordering of `RunSynchronous` versus the disk wipe is **not contractually
> guaranteed** by Microsoft (medium confidence). **Test in a VM with two disks before
> relying on it.** To disable the guard, delete both `RunSynchronousCommand` blocks. The
> fully-guaranteed alternative is to move partitioning into a `diskpart` script called from
> `RunSynchronous`.

---

## ⚙️ 2. setup.ps1

### What it does
PowerShell + Windows Forms GUI in a **single window**: the input form on top and a live
progress section at the bottom (status + progress bar + colored streaming log) that shows
each task — rename, user, network, installers, signature — as it runs, with a **Close**
button when finished. Auto-launched by `autounattend.xml` on first login; `run.bat` is the
manual fallback. Supports `-Unattended` (with `-Test*` parameters) for headless testing —
used by the Sandbox harness (no window).

### Error handling
- **Input is validated and normalized before any action.** The form sanitizes as you type
  (full name accepts letters/spaces/hyphen/apostrophe only; the username is auto-derived from
  First + Last as lowercase `name.surname` with accents stripped, and stays editable for overrides;
  the static IP field masks to four `0-255` octets,
  with Enter to jump between octets) and **blocks submit** with one consolidated, plain-language
  message + per-field markers if anything is still invalid. The same validators re-run at the single point where
  the GUI and headless `-Test*` paths converge, so automation can't drive the script into a
  broken state (a malformed `-TestUsername` aborts `FATAL` before any account is created).
- Every phase is wrapped in `try/catch`; failures are logged `ERROR`/`FATAL` and counted.
- Installer exit codes are checked (non-zero is `ERROR`, not silently `OK`; `3010` = reboot-required counts as success).
- The script **exits non-zero** when any error was tracked, so callers (`run.bat`, `FirstLogonCommands`) detect failure.
- The unhandled-error `trap` aborts (`exit 1`) instead of continuing over inconsistent state.
- Missing optional config never crashes under StrictMode — it is defaulted or validated with a clear message.
- Re-running is idempotent: an existing user / already-applied PC name is detected, not re-created.

### Prerequisite
`config.ps1` must be in the root of the same USB drive as `setup.ps1`. Copy from
`config.example.ps1` and fill in real values.

### config.ps1 — required variables

```powershell
# Admin account
$AdminAccount    = "setupadmin"                 # bootstrap account name — MUST match build-usb.ps1
$AdminNewPass    = "REAL_ADMIN_PASSWORD"        # replaces the bootstrap password; never commit
$UserInitialPass = "USER_INITIAL_PASSWORD"      # new user initial password

# Email domains (GUI dropdown)
$EmailDomains = @('empresa.com.br', 'empresa.org.br')

# Corporate share
$SharePath   = "\\SERVER_IP\share"
$ShareUser   = "USERNAME"
$SharePass   = "SHARE_PASSWORD"

# WiFi (always DHCP — provides internet during provisioning)
$WifiSSID    = "NETWORK_NAME"
$WifiPass    = "WIFI_PASSWORD"

# Static IP for the Ethernet adapter (only when the technician picks "Static IP")
$StaticGateway      = "GATEWAY_IP"
$StaticPrefixLength = 24
$DnsServers         = @('8.8.8.8', '8.8.4.4')

# Wallpaper filename (USB drive root)
$WallpaperFile = 'wallpaper.jpg'

# Paths — all on the USB drive ($ScriptDir = USB root)
$PathOffice     = "$ScriptDir\Office"           # ODT; falls back to OfficeSetup.exe if absent
$PathBelarc     = $ScriptDir
$PathEpson      = "$ScriptDir\Drivers Epson"
$PathWebAgent   = "$ScriptDir\20.WebAgent\windows"
$PathSignatures = "$ScriptDir\assinatura-2026"  # structure: \{domain}\{sector}\user.htm
$PathHBRCloud   = "$ScriptDir\automatizacaoCloud" # HBR Cloud toolkit; omit/empty to skip the HBR step
```

### Execution phases

```
Pre-GUI — Kick off Ninite in the background (longest installer; downloads over WiFi
          while the technician fills the form). WiFi is up since Phase 2.
    ↓
Phase 1 — Load config.ps1; apply OEM license (slmgr); rotate the bootstrap admin password
    ↓
Phase 2 — WiFi (WPA2PSK), load printers.json
    ↓
Phase 3 — GUI (single window): the input form (first + last name -> auto username, email domain,
          network DHCP/Static IP, printer, sector, signature .htm, WebAgent) on top, plus a live
          progress section at the bottom that streams every task below as it runs
    ↓
Phase 4 — Rename PC to BIOS SerialNumber; create local user; configure Ethernet; stage the
          wallpaper to %WINDIR% (applied per-user in Phase B)
    ↓
Phase 5 — Launch the rest of the installers in parallel (Office + Belarc + Epson driver,
          background, no -Wait)
    ↓
Phase 7 — Join all installers (wait + check exit codes) → add printer (poll for driver) →
          WebAgent (MSI, after the pool to respect the Windows Installer mutex) → HBR Cloud
          (copy automatizacaoCloud\ to C:\HBR + run its installer bat hands-free) →
          checklist on screen + full log on the Desktop
    ↓
Phase 8 — Handoff (only with -EnableHandoff): stage C:\ProgramData\CorpSetup (state.json +
          phase-b.ps1/cleanup.ps1 + the signature subtree), register the two scheduled tasks, arm
          the new-user one-shot AutoLogon → reboot into Phase B
    ↓
Phase B — (new user session, after reboot) wallpaper (HKCU), Outlook signature in %APPDATA% set as
          default New+Reply, default printer → drop the user-done flag
    ↓
Cleanup — (SYSTEM) wait for user-done → zero + verify the AutoLogon in HKLM → unregister both tasks
          → delete the staging folder
```

(The Phase 6 signature step moved to Phase B; the numbering gap mirrors `setup.ps1`.)

The Windows Installer global mutex (`_MSIExecute`) means two `msiexec` jobs can't run at
once: Ninite (uses msiexec internally) and WebAgent (MSI) never overlap, while Office
(Click-to-Run, a separate engine), Belarc and Epson run truly in parallel.

### User creation

| Account | Type | Purpose |
|---|---|---|
| `$AdminAccount` (e.g. `setupadmin`) | Administrator | Technical setup account |
| New (username) | Standard User | Day-to-day account |

- The display name is entered as separate **First** and **Last** name fields (Tab between them),
  concatenated and Title-Cased into the read-only "Full name" — used as the account display name
  and in the signature.
- The username is **auto-derived** from those fields as lowercase `firstname.surname` (accents
  stripped, letters + a single dot; `João Silva` → `joao.silva`) so the technician doesn't type
  it. It stays editable for overrides (e.g. duplicate names) and is the Windows login **and** the
  email prefix; the same `name.surname` shape is enforced at submit.
- Initial password: `$UserInitialPass`; never expires; never written to the log.

### Network configuration

WiFi is always DHCP (initial internet). The DHCP/Static choice in the GUI applies to the
**Ethernet** adapter only.

**Static IP** — the technician types only the address; the field auto-inserts dots and
clamps each octet to `0-255` as they type, and submit is blocked unless it is a valid IPv4.
Prefix length (`$StaticPrefixLength`), gateway (`$StaticGateway`) and DNS (`$DnsServers`)
come from `config.ps1`.

### Program installation

| Program | Source | Method |
|---|---|---|
| Ninite | USB root (`ninite.exe`) | Background (started pre-GUI) |
| Microsoft Office | `$PathOffice\setup.exe` + `configuration.xml` (ODT); falls back to USB `OfficeSetup.exe` | ODT `/configure`, background |
| Belarc Advisor | USB root (`belarc.exe`) | `/S` silent, background |
| Epson driver | `Drivers Epson\*.exe` | `/S` silent, background + `Add-Printer` via TCP/IP port |
| WebAgent | `20.WebAgent\windows\` — `.msi` → `.zip` → `.exe` | `msiexec /quiet` or `/S`, after the pool |
| HBR Cloud | `$PathHBRCloud` (`automatizacaoCloud\`) | Copy folder to `C:\HBR`, then run the vendor `Instalar_HBR.bat` hands-free (empty stdin, hidden); creates the `HBRCloud_Logon` task + Defender exclusions; DB registration is best-effort (corporate network only) |

#### Office (ODT)

Office installs via the **Office Deployment Tool**. Two files go in `<USB>\Office\`:
`setup.exe` (the ODT bootstrapper — download at <https://aka.ms/ODT>) and `configuration.xml`
(copy from [`configuration.example.xml`](configuration.example.xml) and pick your product/apps).

`setup.ps1` runs `setup.exe /configure configuration.xml` with the working dir set to the
Office folder. `configuration.xml` is **mandatory** — ODT with no action verb installs nothing
(silent no-op); the script logs an ERROR and skips Office if it is missing.

**Offline (recommended)** — pre-download the Office bits onto the USB once, so every machine
installs from the USB with no internet during setup:

```powershell
cd <USB>\Office
.\setup.exe /download configuration.xml   # fills <USB>\Office\Office\Data\... (a few GB)
```

No `SourcePath` is set in the XML, so ODT finds that local `Office\Data` next to `setup.exe`
automatically — keeping it portable across USB drive letters.

**Online** — skip the `/download`; each machine pulls ~2–4 GB from the Microsoft CDN at
install time (internet required).

### Licensing (OEM — Dell)
Reads `OA3xOriginalProductKey` from UEFI firmware (`Get-CimInstance SoftwareLicensingService`),
then `slmgr /ipk` + `/ato`. Logs WARN if no firmware key.

### Computer rename
Reads `Win32_BIOS.SerialNumber`, validates (skips empty / "To Be Filled" / "O.E.M." /
"Default string"), strips invalid chars, truncates to 15 (NetBIOS), `Rename-Computer -Force`
(effective after reboot).

### Outlook signature
Runs in **Phase B** (the new user's own session). `phase-b.ps1` loads a `.htm` from the staged
`Signatures/{domain}/{sector}/`, replaces the old name (bold `<span>`) and email (regex) with the
values from `state.json`, copies the `<template>_files` logo folder alongside and re-points its
`src=`, saves to the user's `%APPDATA%\Microsoft\Signatures\{username}.htm`, and registers it as the
**default New + Reply** signature (HKCU Office MailSettings) — no longer a manual step.

---

## 🔁 3. Full flow

```
1.  Plug the USB drive into the machine
2.  Power on → boot from USB
3.  [AUTO] guard-disk: proceed only if exactly 1 disk (else abort); disk wiped + formatted (EFI + MSR + Windows)
4.  [AUTO] Windows 11 Pro installed → reboot
5.  [AUTO] Locale configured, entire OOBE skipped
6.  [AUTO] AutoLogon as the bootstrap admin (one time)
7.  [AUTO] setup.ps1 opens automatically (FirstLogonCommands) — run.bat is the manual fallback
8.  [AUTO] OEM license applied + bootstrap admin password rotated
9.  [INTERACTIVE] GUI (single window) — technician fills name/domain/network/printer/sector (username auto-derived from the name); the bottom section then streams steps 10-12 live
10. [AUTO] PC renamed, user created, network configured; wallpaper staged to %WINDIR%
11. [AUTO] Ninite + Office + Belarc + Epson installed in parallel; WebAgent + HBR Cloud after
12. [AUTO] Checklist shown + saved to Desktop; Phase B staged (state.json + 2 tasks + new-user AutoLogon armed)
13. [AUTO] Technician closes the progress window → reboot into Phase B
14. [AUTO] New user autologons → Phase B applies wallpaper (HKCU) + Outlook signature (default New+Reply) + default printer
15. ✅ Cleanup (SYSTEM) zeroes + verifies the AutoLogon, removes the two tasks and the staging — machine ready, hand credentials to the user
```

---

## 🧪 4. How to test

Testing happens at two levels. **CI** runs automatically on every push/PR and checks the
things that can be verified without a real machine; the **end-to-end** paths (Sandbox, VM,
hardware) stay manual because they actually install Windows / mutate the system.

### Continuous integration (automated, on every push/PR)

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on GitHub Actions:

| Check | Tool | What it guards |
|---|---|---|
| Lint | PSScriptAnalyzer ([`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1)) | PowerShell bugs / style |
| Unit tests | Pester 5 ([`tests/unit/`](tests/unit)) | the pure validators in `setup.ps1` (IP, username, name normalization) |
| Secret scan | gitleaks ([`.gitleaks.toml`](.gitleaks.toml)) | no real credential ever lands in the repo |
| XML | `[xml]` parse | `autounattend.template.xml` / `configuration.example.xml` are well-formed |

The unit tests dot-source `setup.ps1` with `-LoadOnly`, which defines the validator functions
and returns before the provisioning body — so they run on any machine and touch nothing.

```powershell
# run the unit tests locally (needs Pester 5):
Invoke-Pester -Path .\tests\unit -Output Detailed
```

> CI does **not** install Windows or create users — that needs the manual e2e paths below.

### setup.ps1 — Windows Sandbox (isolated, recommended)

Runs `setup.ps1` in a throwaway VM that resets on close. No risk to the host.

**Prerequisites:** Windows 10/11 Pro/Enterprise with Windows Sandbox enabled
(Control Panel → Programs → Windows Features → Windows Sandbox).

**Steps:**
1. Launch the prep (path-agnostic — works wherever the repo lives, WSL share or a
   normal Windows folder). Either **double-click `tests\run-sandbox.bat`** (it
   self-elevates with a UAC prompt), or from an **Administrator** PowerShell in the
   repo's `tests/` folder run:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\prep.ps1
   ```
   Admin is needed because `prep.ps1` creates `C:\SandboxTest` at the root of `C:`.
2. `prep.ps1` stages the scripts, injects fake credentials (`test-config.ps1`), opens the Sandbox.
3. `bootstrap.ps1` runs automatically on login: pre-creates the admin account, then runs
   `setup.ps1` **interactively** — the production-like single-window GUI. Fill the form with
   the test fixtures (domain `empresa.com.br`, sector `TI`, printer `Test Printer`) and click
   Start; the bottom section streams every task live.
4. Read the verdict: **`RESULT: PASSED`** (exit 0, zero `ERROR`/`FATAL`) or **`FAILED`**.
   Full log on the Sandbox Desktop.
5. Close the Sandbox → everything is discarded.

**Expected WARNs (not failures):** WiFi (no adapter), SMB share (fake path),
Office/Ninite/Belarc/Epson (binaries absent), OEM activation (no firmware key in a VM) —
logged WARN, not `ERROR`.

**Headless assertion:** for an automated, no-GUI run (CI-style), use
`bootstrap.ps1 -Headless` — it runs `setup.ps1 -Unattended` with test data and prints the
verdict without any interaction.

**Test fixtures:**
| File | Purpose |
|---|---|
| `tests/run-sandbox.bat` | One-click launcher — self-elevating, path-agnostic; runs `prep.ps1` |
| `tests/prep.ps1` | Staging + WSB generator — run on Windows before Sandbox |
| `tests/bootstrap.ps1` | Runs automatically inside Sandbox at login |
| `tests/test-config.ps1` | Fake credentials replacing `config.ps1` |
| `tests/usb-sim/` | Minimal printer list + signature template |

### autounattend.xml (VM)
Generate the file first (`build-usb.ps1`), then:
- **Hyper-V:** Generation 2 (UEFI) VM, Windows 11 ISO as DVD, USB with `autounattend.xml` as a second disk.
- **VirtualBox:** new VM with the ISO, `autounattend.xml` on a virtual floppy (`.img`/`.vfd`).
- **Disk guard:** add a second virtual disk to confirm the install aborts (the guard proceeds only with exactly 1 disk).

---

## 🩺 Troubleshooting

### Windows 11 24H2/25H2 — initial language/keyboard screens

**Symptom:** Setup stops on the language/region and keyboard screens (two manual "Next"
clicks) before the install becomes automatic. *(The disk-guard `cmd` console that flashes
in WinPE is **expected** — a `RunSynchronous` command shows a console — not the problem.)*

**Cause:** two independent triggers produce the same symptom:

1. **ISO language ≠ pt-BR** — an en-US ISO has no pt-BR pack in `boot.wim`, so
   `SetupUILanguage` cannot apply. **Fix:** burn a **pt-BR ISO** (see
   [Burning the boot USB](#burning-the-boot-usb-rufus)). This is the usual cause.
2. **24H2/25H2 "ConX" setup** — since 24H2, WinPE launches the new `SetupPrep.exe`
   front-end, which can ignore the `windowsPE` locale settings **even on a matching ISO**.

**Fix for the ConX case — force the legacy setup.** Edit the media's `boot.wim` (index 2 =
"Windows Setup") so WinPE launches the old `setup.exe`, which honours the whole `windowsPE`
pass. Run `force-legacy-setup.ps1` from an **Administrator** PowerShell on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\force-legacy-setup.ps1 -UsbDrive E   # E: = the USB
```

Or by hand (the script just wraps these):

```powershell
DISM /Mount-Wim /WimFile:E:\sources\boot.wim /Index:2 /MountDir:C:\mnt
reg load HKLM\OFFSYS C:\mnt\Windows\System32\config\SYSTEM
reg add HKLM\OFFSYS\Setup /v CmdLine /t REG_SZ /d "X:\sources\setup.exe" /f
reg unload HKLM\OFFSYS
DISM /Unmount-Wim /MountDir:C:\mnt /Commit
```

> ⚠️ Community-reported, **medium confidence — test in a VM first** (same caution as the
> disk guard). `boot.wim` is < 4 GB so it fits the FAT32 USB; the script clears its
> read-only attribute automatically if Rufus set one.

---

## 🗂️ 5. Repository files

| File | Description |
|---|---|
| `autounattend.template.xml` | Answer-file template (placeholders for admin user/password) |
| `build-usb.ps1` | Generates the real `autounattend.xml` from the template (one-time, at USB build) |
| `build.bat` | Double-click launcher for `build-usb.ps1` (ExecutionPolicy Bypass; stays open) |
| `force-legacy-setup.ps1` | Forces legacy Setup on the boot USB (24H2/25H2 ConX fix; run as admin, test in VM) |
| `setup.ps1` | Post-installation script with GUI |
| `run.bat` | Manual fallback launcher (ExecutionPolicy Bypass) |
| `guard-disk.cmd` | WinPE fail-closed guard: proceeds only if exactly 1 fixed disk (test in VM first) |
| `config.example.ps1` | Configuration template — copy to `config.ps1` on the USB drive |
| `printers.example.json` | Printer-list format reference — copy to `printers.json` |
| `tests/` | Isolated test infrastructure (Windows Sandbox) |
| `.gitignore` | Excludes the generated/secret files (below), binaries, signatures, logs |

**Not versioned (generated or live only on the USB drive):**
- `autounattend.xml` — generated by `build-usb.ps1` (has the bootstrap password)
- `config.ps1` — real credentials (copy from `config.example.ps1`)
- `printers.json` — real printer IPs/sectors (copy from `printers.example.json`)
- `ninite.exe` — download pre-configured at ninite.com
- `wallpaper.jpg` — corporate wallpaper
- `assinatura-2026/` — Outlook signature `.htm` files (employee personal data)
- `Drivers Epson/`, `20.WebAgent/`, `belarc.exe`, `OfficeSetup.exe` — installers

---

## 🚧 Roadmap — intranet auto-provisioning (planned)

Today the technician re-types the same machine/user data into two internal IT web
portals **after** `setup.ps1` finishes. The planned next step is to have `setup.ps1`
**POST the data it already collected** to those portals so their forms auto-fill —
removing the double entry and the typos it causes.

- **User-gateway portal** (SSO user panel) — receives full name, email, username,
  department/role, organization and a default permission profile; it then propagates
  the user to the ticketing/Kanban systems on the next SSO login.
- **IT asset portal** (device registration) — receives device type, responsible
  employee, department/organization, IP, MAC, hostname/asset tag and remote-access
  info (extension, AnyDesk ID).

Principles for the integration:

- **Best-effort, never blocking.** A portal being down logs a `WARN`; provisioning
  still completes. Same contract as every other phase.
- **No secrets in code.** Portal base URLs and API credentials live in `config.ps1`
  (gitignored); never hardcoded. Prefer HTTPS / internal-only reachability.
- **Idempotent.** Look the record up before creating it, so a re-run does not
  duplicate the user/device.

> Detailed endpoint/field mapping, auth flow and PowerShell sketches are kept in an
> **internal** document (`resumo-windows-auto.md`), intentionally **outside this public
> repository** because it references internal hostnames and architecture.

---

## 📄 License

Released under the [MIT License](LICENSE).
