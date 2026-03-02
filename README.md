# artix-install

A simple TUI installer for Artix Linux with dinit(Currently supports dinit. Other init systems may be added in the future.) that gives you a minimal,
(mostly) bloat-free system without sacrificing convenience.

I've always had to choose between manually installing Artix to avoid the
bloat that comes with Calamares, or giving in to that convenience. This
script solves that dilemma.

## What it configures
- Disk partitioning and filesystem (ext4, btrfs, xfs, f2fs)
- Kernel ( zen, lts, standard and custom kernels like cachyos and liquorix kernel)
- Bootloader (GRUB, Limine, rEFInd)
- Swap (zram, swapfile, both or neither)
- CPU microcode and GPU drivers (auto-detected)
- Keyboard layout, locale, timezone
- Audio via PipeWire (note: KDE Plasma audio can be finicky)
- doas instead of sudo
- WiFi (carries your live session connection into the install)
- Optional DE/WM: KDE Plasma, XFCE, LXQt, i3, XMonad, Moksha,
  WindowMaker(compiled from source), COSMIC(experimental), or CLI-only

## Usage
Boot the Artix live ISO, connect to wifi via nmtui, then run the following command as root

```
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install.sh | bash
```

Then just go through the installer it is fairly simple and sit back and relax.
<img width="919" height="992" alt="artix" src="https://github.com/user-attachments/assets/6dd221dc-adae-4560-8f51-e5359297c5e7" />
