# artix-install

A simple TUI installer for Artix Linux with dinit or openrc that gives you a minimal,
(mostly) bloat-free system without sacrificing convenience.

## Why would I choose this over the official installer?

-It gives you the customization of the manual install while making it easy

## What it configures
- Disk partitioning and filesystem (ext4, btrfs, xfs, f2fs)
- Kernel ( zen, lts, standard and custom kernels like cachyos and liquorix kernel)
- Bootloader (GRUB, Limine, rEFInd)
- Swap (zram, swapfile, both or neither)
- CPU microcode and GPU drivers 
- Keyboard layout, locale, timezone
- Audio via PipeWire for desktop environments(note: KDE Plasma audio can be finicky)
- doas or sudo
- WiFi (carries your live session connection into the install)
- Optional DE/WM(note that I ship with the base verison of these but iam considering shipping riced versions of these): Cosmic(perfomance issues), KDE Plasma, XFCE, LXQt, Hyprland, Moksha ///the following wms dont configure audio to reduce bloat: i3, XMonad, ,Icewm, Fluxbox or CLI-only

## Usage
Boot the Artix live ISO(please use the weekly release the stable one is broken), connect to wifi via nmtui, then run the following command as root

```
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install.sh | bash
```

if you want the testing branch run this command instead
```
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install-testing.sh | bash
```


Then just go through the installer it is fairly simple and sit back and relax.
<img width="919" height="992" alt="artix" src="https://github.com/user-attachments/assets/6dd221dc-adae-4560-8f51-e5359297c5e7" />




## Things to add
- [ ] s6 and runit
- [ ] add MORE wms
- [ ] add my own custom kernel
- [ ] add a option to prerice your wm
- [ ] fix the cosmic performance problem
- [ ] step by step guide
