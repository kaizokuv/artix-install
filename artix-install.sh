#!/bin/bash
set -e
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

clear
TITLE="Artix Linux Installer"

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

DISK=$(lsblk -dpno NAME,SIZE | grep -v loop | whiptail \
--title "$TITLE" --menu "Select installation disk" 20 70 10 \
$(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1 " " $2}') \
3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

whiptail --title "$TITLE" --yesno "ALL DATA ON $DISK WILL BE DESTROYED" 10 60 || exit 1

SWAPSIZE=$(whiptail --title "$TITLE" --inputbox "Swap size (e.g. 8G, 0 for no swapfile)" 10 60 "8G" 3>&1 1>&2 2>&3)
SWAPSIZE=$(validate_input "$SWAPSIZE")

FS_CHOICE=$(whiptail --title "$TITLE" --menu "Select Root Filesystem" 15 60 4 \
"ext4" "Standard Ext4" \
"xfs" "XFS Filesystem" \
"btrfs" "B-Tree Filesystem" \
"f2fs" "Flash-Friendly Filesystem" 3>&1 1>&2 2>&3)

TYPE_CHOICE=$(whiptail --title "$TITLE" --menu "Install Desktop Environment or Window Manager?" 15 60 2 \
"DE" "Desktop Environment" \
"WM" "Window Manager" 3>&1 1>&2 2>&3)

if [[ "$TYPE_CHOICE" == "DE" ]]; then
    DE_CHOICE=$(whiptail --title "$TITLE" --menu "Select Desktop Environment" 20 70 6 \
    "Plasma" "KDE Plasma" \
    "XFCE" "XFCE4" \
    "MATE" "MATE Desktop" \
    "LXQt" "LXQt Desktop" \
    "Moksha" "Moksha Desktop" \
    "None" "CLI Only" 3>&1 1>&2 2>&3)
else
    WM_CHOICE=$(whiptail --title "$TITLE" --menu "Select Window Manager" 20 70 6 \
    "i3" "i3 Tiling" \
    "xmonad" "xmonad Tiling" \
    "WindowMaker" "WindowMaker" 3>&1 1>&2 2>&3)
fi

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
    ext4) mkfs.ext4 -F "$ROOT" ;;
    xfs)  mkfs.xfs -f "$ROOT" ;;
    btrfs) mkfs.btrfs -f "$ROOT" ;;
    f2fs) mkfs.f2fs -f "$ROOT" ;;
esac

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

if [[ "$SWAPSIZE" != "0" ]]; then
    dd if=/dev/zero of=/mnt/swapfile bs=1M count=$(( ${SWAPSIZE%G} * 1024 )) status=progress
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
fi

BASE_PKGS="base base-devel linux linux-firmware intel-ucode dbus-dinit elogind-dinit doas vi networkmanager networkmanager-dinit grub efibootmgr ntfs-3g dosfstools mtools whiptail"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber"
FS_PKGS=""
[[ "$FS_CHOICE" == "btrfs" ]] && FS_PKGS="btrfs-progs"
[[ "$FS_CHOICE" == "xfs" ]] && FS_PKGS="xfsprogs"
[[ "$FS_CHOICE" == "f2fs" ]] && FS_PKGS="f2fs-tools"
SWAP_PKGS=""
[[ "$SWAPSIZE" != "0" ]] && SWAP_PKGS="zramen zramen-dinit"

basestrap /mnt $BASE_PKGS $AUDIO_PKGS $FS_PKGS $SWAP_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab
[[ "$SWAPSIZE" != "0" ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

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

echo "permit persist :wheel" > /mnt/etc/doas.conf
artix-chroot /mnt chown root:root /etc/doas.conf
artix-chroot /mnt chmod 0400 /etc/doas.conf

# Audio autostart for both DE and WM
mkdir -p /mnt/home/$USERNAME/.config/autostart
cat <<EOF > /mnt/home/$USERNAME/.config/autostart/pipewire.desktop
[Desktop Entry]
Type=Application
Exec=/usr/bin/pipewire
Name=PipeWire
EOF
cat <<EOF > /mnt/home/$USERNAME/.config/autostart/wireplumber.desktop
[Desktop Entry]
Type=Application
Exec=/usr/bin/wireplumber
Name=WirePlumber
EOF
chown -R $USERNAME:$USERNAME /mnt/home/$USERNAME/.config

# xinitrc for WMs
if [[ "$TYPE_CHOICE" == "WM" ]]; then
    cat <<EOF > /mnt/home/$USERNAME/.xinitrc
#!/bin/bash
/usr/bin/dbus-launch --exit-with-session pipewire &
/usr/bin/dbus-launch --exit-with-session wireplumber &
exec $WM_CHOICE
EOF
    chown $USERNAME:$USERNAME /mnt/home/$USERNAME/.xinitrc
    chmod +x /mnt/home/$USERNAME/.xinitrc
fi

if [[ "$TYPE_CHOICE" == "DE" ]]; then
    case $DE_CHOICE in
        Plasma) artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm-dinit ;;
        XFCE) artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies lightdm-dinit ;;
        MATE) artix-chroot /mnt pacman -S --noconfirm mate mate-extra lightdm-dinit ;;
        LXQt) artix-chroot /mnt pacman -S --noconfirm lxqt sddm-dinit ;;
        Moksha) artix-chroot /mnt pacman -S --noconfirm moksha-artix lightdm-dinit ;;
    esac
fi

artix-chroot /mnt mkdir -p /etc/dinit.d/boot.d
for svc in dbus NetworkManager elogind zramen; do
    [ -f "/mnt/etc/dinit.d/$svc" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done

artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

umount -R /mnt
sync

if whiptail --title "$TITLE" --yesno "Installation complete! Reboot now?" 10 60; then
    reboot
fi
