#!/bin/bash

set -e
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

clear
TITLE="Artix Linux Installer"

# Helper for whiptail passwords
get_password() {
    local prompt="$1"
    local pw=""
    while [ -z "$pw" ]; do
        pw=$(whiptail --title "$TITLE" --passwordbox "$prompt" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && exit 1
    done
    echo "$pw"
}

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
--menu "Select installation disk (Use arrows/type first letter)" 20 70 10 \
$(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1 " " $2}') \
3>&1 1>&2 2>&3)

[ -z "$DISK" ] && exit 1

whiptail --title "$TITLE" --yesno "ALL DATA ON $DISK WILL BE DESTROYED" 10 60 || exit 1

# 2. Cleanup & Partitioning
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK"

fdisk "$DISK" <<EOF
g
n
1

+1G
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

# 3. Basestrap
basestrap /mnt \
base base-devel linux linux-firmware intel-ucode amd-ucode \
dinit elogind-dinit dbus-dinit doas vi \
networkmanager networkmanager-dinit \
pipewire pipewire-alsa pipewire-pulse wireplumber \
zramen zramen-dinit grub efibootmgr \
ntfs-3g dosfstools mtools libnewt

fstabgen -U /mnt >> /mnt/etc/fstab

# 4. Desktop Environment Selection
DE_CHOICE=$(whiptail --title "$TITLE" --menu "Select Desktop Environment" 20 70 6 \
"Plasma" "KDE Plasma Full Suite" \
"XFCE" "XFCE4 + Goodies (Lightweight)" \
"MATE" "MATE Desktop + Extra" \
"LXQt" "LXQt Desktop" \
"Moksha" "Moksha Desktop (Enlightenment fork)" \
"None" "Standard CLI only" 3>&1 1>&2 2>&3)

# 5. Localization (Whiptail menus allow jumping by typing the first letter)
LOCALE=$(whiptail --title "$TITLE" --menu "Select locale (Type letter to jump)" 20 70 10 \
$(grep "UTF-8" /mnt/usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
LOCALE=$(validate_input "$LOCALE")

echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
artix-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf

TIMEZONE=$(whiptail --title "$TITLE" --menu "Select timezone (Type letter to jump)" 20 70 10 \
$(awk '/^[^#]/ {print $3 " " $3}' /mnt/usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)
TIMEZONE=$(validate_input "$TIMEZONE")

artix-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
artix-chroot /mnt hwclock --systohc

# 6. Hostname & User Configuration
HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Enter hostname" 10 60 artix 3>&1 1>&2 2>&3)
HOSTNAME=$(validate_input "$HOSTNAME")
echo "$HOSTNAME" > /mnt/etc/hostname

ROOT_PW=$(get_password "Enter Root Password")
echo "root:$ROOT_PW" | artix-chroot /mnt chpasswd

USERNAME=$(whiptail --title "$TITLE" --inputbox "Enter username" 10 60 user 3>&1 1>&2 2>&3)
USERNAME=$(validate_input "$USERNAME")
USER_PW=$(get_password "Enter password for $USERNAME")

artix-chroot /mnt useradd -m -G wheel,audio,video,storage "$USERNAME"
echo "$USERNAME:$USER_PW" | artix-chroot /mnt chpasswd

# Setup doas
echo "permit persist :wheel" > /mnt/etc/doas.conf
artix-chroot /mnt chown root:root /etc/doas.conf
artix-chroot /mnt chmod 0400 /etc/doas.conf

# 7. Install Desktop Environment
case $DE_CHOICE in
    Plasma) artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm-dinit ;;
    XFCE)   artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies lightdm-dinit ;;
    MATE)   artix-chroot /mnt pacman -S --noconfirm mate mate-extra system-config-printer blueman connman-gtk lightdm-dinit ;;
    LXQt)   artix-chroot /mnt pacman -S --noconfirm lxqt sddm-dinit ;;
    Moksha) artix-chroot /mnt pacman -S --noconfirm moksha-artix lightdm-dinit ;;
    None)   echo "No DE selected." ;;
esac

# 8. Services & Bootloader
artix-chroot /mnt mkdir -p /etc/dinit.d/boot.d
# Enable display manager if a DE was chosen
[[ "$DE_CHOICE" == "Plasma" || "$DE_CHOICE" == "LXQt" ]] && DM="sddm"
[[ "$DE_CHOICE" == "XFCE" || "$DE_CHOICE" == "MATE" || "$DE_CHOICE" == "Moksha" ]] && DM="lightdm"

for svc in dbus NetworkManager elogind zramen $DM; do
    [ -f "/mnt/etc/dinit.d/$svc" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done

artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# 9. Cleanup
umount -R /mnt
sync

whiptail --title "$TITLE" --msgbox "Installation complete! Rebooting..." 10 60
reboot
