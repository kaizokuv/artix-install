#!/bin/bash

set -e
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

clear

TITLE="Artix Linux Installer"

# Helper function to validate input
validate_input() {
    local input="$1"
    if [ -z "$input" ]; then
        whiptail --title "$TITLE" --msgbox "Input cannot be empty. Installation cancelled." 10 60
        exit 1
    fi
    echo "$input"
}

DISK=$(lsblk -dpnoNAME,SIZE | grep -v loop | whiptail \
--title "$TITLE" \
--menu "Select installation disk" 20 70 10 \
$(lsblk -dpnoNAME,SIZE | grep -v loop | awk '{print $1 " " $2}') \
3>&1 1>&2 2>&3)

[ -z "$DISK" ] && exit 1

whiptail --title "$TITLE" --yesno "ALL DATA ON $DISK WILL BE DESTROYED" 10 60 || exit 1

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8300 "$DISK"

EFI="${DISK}1"
ROOT="${DISK}2"

mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

basestrap /mnt \
base base-devel \
linux linux-firmware \
dinit elogind-dinit \
doas vi \
networkmanager networkmanager-dinit \
pipewire pipewire-alsa pipewire-pulse wireplumber \
zramen \
grub efibootmgr \
ntfs-3g dosfstools mtools \
whiptail

if [ $? -ne 0 ]; then
    whiptail --title "$TITLE" --msgbox "basestrap failed. Installation aborted." 10 60
    exit 1
fi

fstabgen -U /mnt >> /mnt/etc/fstab

LOCALE=$(whiptail \
--title "$TITLE" \
--menu "Select locale" 20 70 10 \
$(grep "UTF-8" /mnt/usr/share/i18n/SUPPORTED | head -20 | awk '{print $1 " (UTF-8)"}') \
3>&1 1>&2 2>&3)

LOCALE=$(validate_input "$LOCALE")

echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen

arch-chroot /mnt locale-gen

echo "LANG=$LOCALE" > /mnt/etc/locale.conf

# Timezone selection
TIMEZONE=$(whiptail \
--title "$TITLE" \
--menu "Select timezone" 20 70 10 \
$(timedatectl list-timezones | head -20 | awk '{print $1 " "}') \
3>&1 1>&2 2>&3)

TIMEZONE=$(validate_input "$TIMEZONE")

arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
arch-chroot /mnt hwclock --systohc

HOSTNAME=$(whiptail \
--title "$TITLE" \
--inputbox "Enter hostname" 10 60 artix \
3>&1 1>&2 2>&3)

HOSTNAME=$(validate_input "$HOSTNAME")

echo "$HOSTNAME" > /mnt/etc/hostname

arch-chroot /mnt passwd

USERNAME=$(whiptail \
--title "$TITLE" \
--inputbox "Enter username" 10 60 user \
3>&1 1>&2 2>&3)

USERNAME=$(validate_input "$USERNAME")

arch-chroot /mnt useradd -m -G wheel,audio,video,storage "$USERNAME"

arch-chroot /mnt passwd "$USERNAME"

echo "permit persist :wheel" > /mnt/etc/doas.conf

arch-chroot /mnt chown root:root /etc/doas.conf
arch-chroot /mnt chmod 0400 /etc/doas.conf

arch-chroot /mnt ln -s /etc/dinit.d/networkmanager /etc/dinit.d/boot.d/

arch-chroot /mnt ln -s /etc/dinit.d/elogind /etc/dinit.d/boot.d/

arch-chroot /mnt ln -s /etc/dinit.d/zramen /etc/dinit.d/boot.d/

arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix

arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

whiptail --title "$TITLE" --yesno "Installation complete. Reboot?" 10 60

if [ $? -eq 0 ]; then
    reboot
fi
