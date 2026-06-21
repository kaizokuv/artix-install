# artix-install

> A TUI installer written in Bash for Artix Linux — minimal, tailored, and convenient.

---

## Why use this over the official installer?

The official installer gives you a working system. This one gives you *your* system — with the flexibility of a manual install and none of the tedium.

---

## What it configures

> The tables below reflect the **testing** script. The **stable** script is a
> more conservative subset — see the notes under each table for what stable
> leaves out.

### Core

| Category | Options |
|---|---|
| **Init system** | dinit, openrc, runit, s6 |
| **Bootloader** | GRUB, Limine, rEFInd |
| **Kernels** | standard, lts, zen · custom: CachyOS (`linux-cachyos`), Liquorix (`linux-lqx`) |
| **Filesystem** | ext4, btrfs, xfs, f2fs, jfs, nilfs2, zfs¹ |
| **Swap** | zram, swapfile, both, dedicated partition, or none |
| **Hardware** | CPU microcode, GPU drivers, firmware auto-detection |
| **Locale** | keyboard layout, locale, timezone (timezone auto-detected from IP) |
| **Mirrors** | auto-ranked by speed at install time |
| **Privilege escalation** | doas or sudo |
| **X11 server** | XLibre or Xorg |
| **Networking** | NetworkManager (carries live WiFi into the install), iwd, dhcpcd |

¹ **ZFS root is experimental and may not boot** without manual post-install
configuration (no `zfs` initramfs hook or `root=ZFS=` cmdline is set up yet).
You are warned and asked to confirm before it is used.

### Desktops, audio, repos, shells

| Category | Options |
|---|---|
| **DE / WM** | Plasma, XFCE, LXQt, GNOME² · i3, bspwm, herbstluftwm, XMonad, Openbox, Fluxbox, IceWM, dwm³ · Sway, Hyprland, niri, river, wayfire, labwc · Moksha |
| **Greeters** | none, LightDM (GTK / Slick), SDDM, greetd (tuigreet / ReGreet / nwg-hello) |
| **Audio** | PipeWire, PulseAudio, ALSA |
| **AUR helper** | yay (installed as a prebuilt binary from the CachyOS repo) |
| **Extra repos** | multilib, Arch `extra`, CachyOS, Galaxy |
| **Shell** | bash, zsh, fish, sh |

² **GNOME** is an older, unmaintained build — Artix dropped it because upstream
depends heavily on systemd. The installer warns you before installing it.
³ **dwm** needs manual source patching after install; the installer only sets up
the base packages.

**Stable vs. testing:** the stable script ships a smaller, more-tested set of
the above (fewer window managers, no AUR helper, and only the most reliable
greeters/repos). The exact stable subset lives in `artix-install.sh`; everything
listed in the tables is available in `artix-install-testing.sh`.

---

## Known issues

- The **stable Artix ISO is currently broken** — it fails even with the official
  manual install. **Use the weekly ISO instead.** This is an upstream ISO problem,
  not an installer bug.
- **ZFS root** may not boot without manual setup (see note above).

---

## Usage

### 1 — Download the weekly ISO

Grab the **weekly release** (not the stable one) from the Artix download page:

https://artixlinux.org/download.php

### 2 — Flash the ISO

Using `dd` (or Ventoy, balenaEtcher, Rufus, Popsicle, etc.):

```bash
dd if=path/to/artix.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with your USB device (e.g. `/dev/sdb`) — double-check it with
`lsblk` first, as this erases the target.

### 3 — Boot and connect to the internet

Boot the ISO. Log in as `root` with password `artix`, then connect.

For WiFi on a NetworkManager-based ISO:

```bash
nmtui
```

> If `nmtui` isn't available on your ISO variant, use `connmanctl` or `iwctl`
> instead, depending on what the live image ships.

### 4 — Run the installer

**Stable** — fewer features, more tested:

```bash
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install.sh | bash
```

**Testing** — more features, less stability:

```bash
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install-testing.sh | bash
```

---

## Video showcase

https://github.com/user-attachments/assets/5d8f86a4-9198-41d7-8f3c-f41f701b747e
