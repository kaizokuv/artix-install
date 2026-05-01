
# Artix-install

#### A TUI installer written in bash for Artix Linux that aims to give you a minimal and tailored system without sacrificing convenience.

## Why would I choose this over the official installer?

- It gives you the customization of the manual install while making it easy

## What it configures
- Disk partitioning and filesystem (ext4, btrfs, xfs, f2fs and more)
- Kernel/s (standard, lts, zen and custom kernels: cachyos, liquorix kernel and XanMod which is avalibe in testing )
- Bootloader (GRUB, Limine, rEFInd)
- Swap (zram, swapfile, both or neither)
- CPU microcode and GPU drivers 
- Keyboard layout, locale, timezone
- Audio - pipewire, pulse or alsa
- Mirros - autopicks the fastest
- Shell - zsh, bash or fish
- Doas or Sudo
- Xorg or Xlibre if youre using X
- WiFi (carries your live session connection into the install if youre going to use network manager)
- Aur(yay, paru or none) - availble in testing
- Repos (lets you enable 32bit ones arch support cachyos and repos galaxy repos) - avalible in stable to some degreee but the testing lets you enable more repos
- DE/WM(you can also pick cli dont worry): KDE Plasma, XFCE, LXQt, Hyprland, Moksha, i3, XMonad, Icewm, Fluxbox, the following are only avalibe in testing sway, dwm and bspwm
- Prericing of your window manager: The rices are made by the cachyos devs I just stole them

## Known issues
- stable release of the iso doesnt work with this installer
- aur autoconfig is broken

## Usage
1.Dowload the WEEKLY iso release NOT THE STABLE one from the artix linux site
https://artixlinux.org/download.php

2.Flash your iso iam going to use dd as an example you can also use ventoy,balena etcher, rufus, popsicle etc.
```
dd if=pathtoyouriso of=/dev/sdX bs=4M status=progress oflag=sync
```


3.Boot your iso login is root password is artix and then run Netowork manager to connect to wifi with an user frindly tui
 
 ```
 nmtui
 ```
4.And the last step is curling the script pick either the regular or testing 

### for the regular release of the script - less features more tested
```
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install.sh | bash
```
### for the testing release of the script - more features less stability
```
curl -sL https://raw.githubusercontent.com/feribsd/artix-install/main/artix-install-testing.sh | bash
```
### video showcase of the installation process in a virtual machine:


https://github.com/user-attachments/assets/5d8f86a4-9198-41d7-8f3c-f41f701b747e

