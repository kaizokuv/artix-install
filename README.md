# artix-install

A simple TUI installer for Artix Linux with dinit or openrc that gives you a minimal,
(mostly) bloat-free system without sacrificing convenience.

## Why would I choose this over the official installer?
- Well calamares is bloated installing it on a shitbox might be a pain loading a graphical session.

- It installs only the necessary packages aka less bloat

- It configures wifi and audio for you which is a plus for me

- Adds the choice that you secretly crave custom kernels bootloader and additional wms/des it provides you with all of the customization that you could ever want

- doas is simply better


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
- Optional DE/WM(note that I ship with the base verison of these but iam considering shipping riced versions of these): Cosmic(perfomance issues), KDE Plasma, XFCE, LXQt, Hyprland, Moksha ///the following wms dont configure audio to reduce bloat: i3, XMonad, ,Icewm, Fluxbox or CLI-only

## Usage
Boot the Artix live ISO, connect to wifi via nmtui, then run the following command as root

```
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install.sh | bash
```

Then just go through the installer it is fairly simple and sit back and relax.
<img width="919" height="992" alt="artix" src="https://github.com/user-attachments/assets/6dd221dc-adae-4560-8f51-e5359297c5e7" />




## Things to add
- [ ] s6 and runit
- [ ] add MORE wms
- [ ] improve the ram usage
- [ ] add my own custom kernel
- [ ] add a option to prerice your wm
