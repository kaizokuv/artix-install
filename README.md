<img width="1500" height="500" alt="image" src="https://github.com/user-attachments/assets/8ecc2c34-c05e-4582-9e10-2ee3913708f8" />

# artix-install

> A TUI installer written in Bash for Artix Linux — minimal, tailored, and convenient.

---

## Why use this over the official installer?

The official installer gives you a working system. This one gives you *your* system — with the flexibility of a manual install and none of the tedium.

---

## What it configures

| Category | Options |
|---|---|
| **Disk & Filesystem** | ext4, btrfs, xfs, f2fs, zfs and more |
| **Kernels** | standard, lts, zen · custom: CachyOS, Liquorix |
| **Bootloader** | GRUB, Limine, rEFInd |
| **Swap** | zram, swapfile, both, or none |
| **Hardware** | Firmware, GPU drivers |
| **Locale** | keyboard layout, locale, timezone |
| **Audio** | PipeWire, PulseAudio, ALSA |
| **Mirrors** | auto-picks fastest on install |
| **Shell**(testing) | bash, zsh, fish, sh |
| **Privilege escalation** | doas or sudo |
| **X11 server** | Xorg or XLibre |
| **Networking** | NetworkManager (carries live WiFi into install), iwd, dhcpcd |
| **Repos**(testing) | multilib, Arch, CachyOS, Galaxy |
| **DE / WM** | KDE Plasma, XFCE, LXQt, Hyprland, Moksha, i3, XMonad, IceWM, Fluxbox · sway, bspwm (untested) |


---

## Known issues

- The **stable ISO does not work** with this installer — **use the weekly ISO** instead
---

## Usage

### 1 — Download the weekly ISO

Download the **weekly release** from the Artix Linux website — **not the stable one**.

https://artixlinux.org/download.php

### 2 — Flash the ISO

Using `dd` (you can also use Ventoy, Balena Etcher, Rufus, Popsicle, etc.):

```bash
dd if=path/to/artix.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### 3 — Boot and connect to WiFi

Boot the ISO. Login is `root`, password is `artix`. Then connect to WiFi with:

```bash
nmtui
```

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
