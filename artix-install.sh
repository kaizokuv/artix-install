#!/bin/bash
set -e
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

clear
TITLE="Artix Linux Installer"

# Helper functions
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

# 2. Swap size input
SWAPSIZE=$(whiptail --title "$TITLE" --inputbox "Enter swap size (e.g., 8G):" 10 60 "8G" 3>&1 1>&2 2>&3)
SWAPSIZE=$(validate_input "$SWAPSIZE")

# 3. File System choice
FS_CHOICE=$(whiptail --title "$TITLE" --menu "Select Root File System" 15 60 4 \
"ext4" "Standard Ext4" \
"xfs" "XFS Filesystem" \
"btrfs" "B-Tree Filesystem" \
"f2fs" "Flash-Friendly Filesystem" 3>&1 1>&2 2>&3)
FS_CHOICE=$(validate_input "$FS_CHOICE")

# 4. DE or WM choice
TYPE_CHOICE=$(whiptail --title "$TITLE" --menu "Install Desktop Environment or Window Manager?" 15 60 2 \
"DE" "Desktop Environment" \
"WM" "Window Manager" 3>&1 1>&2 2>&3)
TYPE_CHOICE=$(validate_input "$TYPE_CHOICE")

if [[ "$TYPE_CHOICE" == "DE" ]]; then
    DE_CHOICE=$(whiptail --title "$TITLE" --menu "Select Desktop Environment" 20 70 6 \
    "Plasma" "KDE Plasma Full Suite" \
    "XFCE" "XFCE4 + Goodies" \
    "MATE" "MATE Desktop + Extras" \
    "LXQt" "LXQt Desktop" \
    "Moksha" "Moksha Desktop (Enlightenment fork)" \
    "None" "CLI only" 3>&1 1>&2 2>&3)
    DE_CHOICE=$(validate_input "$DE_CHOICE")
else
    WM_CHOICE=$(whiptail --title "$TITLE" --menu "Select Window Manager" 20 70 6 \
    "i3" "i3 Tiling WM" \
    "xmonad" "xmonad Tiling WM" \
    "WindowMaker" "Classic WindowMaker WM" 3>&1 1>&2 2>&3)
    WM_CHOICE=$(validate_input "$WM_CHOICE")
fi

# 5. Cleanup & Partitioning
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

[[ "$DISK" =~ [0-9]$ ]] && P="p" || P=""
EFI="${DISK}${P}1"
ROOT="${DISK}${P}2"

mkfs.fat -F32 "$EFI"
case $FS_CHOICE in
    ext4)  mkfs.ext4 -F "$ROOT" ;;
    xfs)   mkfs.xfs -f "$ROOT" ;;
    btrfs) mkfs.btrfs -f "$ROOT" ;;
    f2fs)  mkfs.f2fs -f "$ROOT" ;;
esac

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# Swapfile creation
if [[ "$SWAPSIZE" != "0" ]]; then
    dd if=/dev/zero of=/mnt/swapfile bs=1M count=$(( ${SWAPSIZE%G} * 1024 )) status=progress
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
    swapon /mnt/swapfile
fi

# 6. Basestrap packages
BASE_PKGS="base base-devel linux linux-firmware intel-ucode amd-ucode dinit elogind-dinit dbus-dinit doas vi networkmanager networkmanager-dinit grub efibootmgr ntfs-3g dosfstools mtools whiptail"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils pavucontrol"
FS_PKGS=""
[[ "$FS_CHOICE" == "btrfs" ]] && FS_PKGS="btrfs-progs"
[[ "$FS_CHOICE" == "xfs" ]] && FS_PKGS="xfsprogs"
[[ "$FS_CHOICE" == "f2fs" ]] && FS_PKGS="f2fs-tools"

basestrap /mnt $BASE_PKGS $AUDIO_PKGS $FS_PKGS

fstabgen -U /mnt >> /mnt/etc/fstab
[[ -f /mnt/swapfile ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# 7. Locale & Timezone
LOCALE=$(whiptail --title "$TITLE" --menu "Select locale" 20 70 10 \
$(grep "UTF-8" /mnt/usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
LOCALE=$(validate_input "$LOCALE")
echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
artix-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf

TIMEZONE=$(whiptail --title "$TITLE" --menu "Select timezone" 20 70 10 \
$(awk '/^[^#]/ {print $3 " " $3}' /mnt/usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)
TIMEZONE=$(validate_input "$TIMEZONE")
artix-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
artix-chroot /mnt hwclock --systohc

# 8. Hostname & User
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

# DOAS
echo "permit persist :wheel" > /mnt/etc/doas.conf
artix-chroot /mnt chown root:root /etc/doas.conf
artix-chroot /mnt chmod 0400 /etc/doas.conf

# 9. Audio Autostart
mkdir -p /mnt/home/$USERNAME/.config/autostart
cat <<EOL > /mnt/home/$USERNAME/.config/autostart/pipewire.desktop
[Desktop Entry]
Type=Application
Exec=/usr/bin/pipewire
Hidden=false
X-GNOME-Autostart-enabled=true
Name=PipeWire
EOL

cat <<EOL > /mnt/home/$USERNAME/.config/autostart/wireplumber.desktop
[Desktop Entry]
Type=Application
Exec=/usr/bin/wireplumber
Hidden=false
X-GNOME-Autostart-enabled=true
Name=WirePlumber
EOL

chown -R $USERNAME:$USERNAME /mnt/home/$USERNAME/.config

# xinitrc for WMs
if [[ "$TYPE_CHOICE" == "WM" ]]; then
    cat <<EOL > /mnt/home/$USERNAME/.xinitrc
#!/bin/bash
/usr/bin/pipewire &
/usr/bin/wireplumber &
exec $WM_CHOICE
EOL
    chown $USERNAME:$USERNAME /mnt/home/$USERNAME/.xinitrc
    chmod +x /mnt/home/$USERNAME/.xinitrc
fi

# 10. DE / WM installation
if [[ "$TYPE_CHOICE" == "DE" ]]; then
    case $DE_CHOICE in
        Plasma) artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm-dinit ;;
        XFCE)   artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies lightdm-dinit ;;
        MATE)   artix-chroot /mnt pacman -S --noconfirm mate mate-extra system-config-printer blueman connman-gtk lightdm-dinit ;;
        LXQt)   artix-chroot /mnt pacman -S --noconfirm lxqt sddm-dinit ;;
        Moksha) artix-chroot /mnt pacman -S --noconfirm moksha-artix lightdm-dinit ;;
        None)   echo "No DE selected." ;;
    esac
fi

# 11. Services & Bootloader
artix-chroot /mnt mkdir -p /etc/dinit.d/boot.d
for svc in dbus NetworkManager elogind zramen; do
    [ -f "/mnt/etc/dinit.d/$svc" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done
[[ "$TYPE_CHOICE" == "DE" ]] && [[ "$DE_CHOICE" == "Plasma" || "$DE_CHOICE" == "LXQt" ]] && DM="sddm"
[[ "$TYPE_CHOICE" == "DE" ]] && [[ "$DE_CHOICE" == "XFCE" || "$DE_CHOICE" == "MATE" || "$DE_CHOICE" == "Moksha" ]] && DM="lightdm"
[[ "$TYPE_CHOICE" == "DE" ]] && [ -n "$DM" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$DM /etc/dinit.d/boot.d/

artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# 12. Finish
umount -R /mnt
sync

if whiptail --title "$TITLE" --yesno "Installation complete! Reboot now?" 10 60; then
    reboot
else
    clear
    echo "Installation finished. You are still in the live environment."
    echo "To chroot into your new system:"
    echo "  artix-chroot /mnt"
    echo "Then type 'reboot' when ready."
fi
