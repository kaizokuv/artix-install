#!/bin/bash

set -e
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

clear
TITLE="Artix Linux Installer"

validate_input() {
    local input="$1"
    if [ -z "$input" ]; then
        whiptail --title "$TITLE" --msgbox "Input cannot be empty. Installation cancelled." 10 60
        exit 1
    fi
    echo "$input"
}

# 1. Disk Selection
DISK=$(lsblk -dpno NAME,SIZE | grep -v loop | whiptail \
--title "$TITLE" \
--menu "Select installation disk" 20 70 10 \
$(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1 " " $2}') \
3>&1 1>&2 2>&3)

[ -z "$DISK" ] && exit 1

whiptail --title "$TITLE" --yesno "ALL DATA ON $DISK WILL BE DESTROYED" 10 60 || exit 1

# 2. Cleanup & Partitioning (Using fdisk)
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK"

# Scripting fdisk: g (GPT), n (new), 1 (partition 1), default start, +512M, 
# t (type), 1 (EFI), n (new), 2 (partition 2), default start/end, w (write)
fdisk "$DISK" <<EOF
g
n
1

+512M
t
1
n
2


w
EOF

udevadm settle
sleep 2

if [[ "$DISK" =~ [0-9]$ ]]; then
    EFI="${DISK}p1"
    ROOT="${DISK}p2"
else
    EFI="${DISK}1"
    ROOT="${DISK}2"
fi

mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# 3. Base Installation
basestrap /mnt \
base base-devel \
linux linux-firmware intel-ucode amd-ucode \
dinit elogind-dinit dbus-dinit \
doas vi \
networkmanager networkmanager-dinit \
pipewire pipewire-alsa pipewire-pulse wireplumber \
zramen zramen-dinit \
grub efibootmgr \
ntfs-3g dosfstools mtools \
whiptail

fstabgen -U /mnt >> /mnt/etc/fstab

# 4. Network Migration
# This copies your current Wi-Fi/Ethernet profiles to the target system
mkdir -p /mnt/etc/NetworkManager/system-connections/
cp -L /etc/NetworkManager/system-connections/* /mnt/etc/NetworkManager/system-connections/ 2>/dev/null || true
chmod 600 /mnt/etc/NetworkManager/system-connections/* 2>/dev/null || true

# 5. Localization & Timezone
LOCALE=$(whiptail --title "$TITLE" --menu "Select locale" 20 70 10 \
$(grep "UTF-8" /mnt/usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
LOCALE=$(validate_input "$LOCALE")
echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf

TIMEZONE=$(whiptail --title "$TITLE" --menu "Select timezone" 20 70 10 \
$(awk '/^[^#]/ {print $3 " " $3}' /mnt/usr/share/zoneinfo/zone.tab) 3>&1 1>&2 2>&3)
TIMEZONE=$(validate_input "$TIMEZONE")
arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
arch-chroot /mnt hwclock --systohc

# 6. Hostname & Users
HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Enter hostname" 10 60 artix 3>&1 1>&2 2>&3)
HOSTNAME=$(validate_input "$HOSTNAME")
echo "$HOSTNAME" > /mnt/etc/hostname

arch-chroot /mnt passwd
USERNAME=$(whiptail --title "$TITLE" --inputbox "Enter username" 10 60 user 3>&1 1>&2 2>&3)
USERNAME=$(validate_input "$USERNAME")
arch-chroot /mnt useradd -m -G wheel,audio,video,storage "$USERNAME"
arch-chroot /mnt passwd "$USERNAME"

echo "permit persist :wheel" > /mnt/etc/doas.conf
arch-chroot /mnt chown root:root /etc/doas.conf
arch-chroot /mnt chmod 0400 /etc/doas.conf

# 7. Dinit Services
arch-chroot /mnt mkdir -p /etc/dinit.d/boot.d
for svc in dbus NetworkManager elogind zramen; do
    arch-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done

# 8. Bootloader
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# 9. Finish
umount -R /mnt
sync

if whiptail --title "$TITLE" --yesno "Installation complete. Reboot?" 10 60; then
    reboot
fi
