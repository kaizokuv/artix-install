#!/bin/bash
set -e
set -o pipefail

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

clear
TITLE="Artix Linux Master Installer"

# --- HELPERS ---
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
    if [ -z "$input" ]; then exit 1; fi
    echo "$input"
}

# --- STAGE 1: FRONT-LOADED INPUTS ---
# We gather everything NOW so the script runs non-interactively later.

DISK=$(lsblk -dpnoNAME,SIZE | grep -v loop | whiptail --title "$TITLE" --menu "Select Disk" 20 70 10 $(lsblk -dpnoNAME,SIZE | grep -v loop | awk '{print $1 " " $2}') 3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

FS_CHOICE=$(whiptail --title "$TITLE" --menu "Root Filesystem" 15 60 4 "ext4" "Standard Ext4" "btrfs" "B-Tree Filesystem" "xfs" "XFS" "f2fs" "Flash-Friendly" 3>&1 1>&2 2>&3)

SWAP_CHOICE=$(whiptail --title "$TITLE" --menu "Swap Configuration" 15 60 4 "Zram" "Use zramen" "Swapfile" "4GB Swapfile" "Both" "Zram + 4GB Swapfile" "None" "No Swap" 3>&1 1>&2 2>&3)

# Localization (Read from LIVE environment to prevent the /mnt crash)
LOCALE=$(whiptail --title "$TITLE" --menu "Select locale" 20 70 10 $(grep "UTF-8" /usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
TIMEZONE=$(whiptail --title "$TITLE" --menu "Select timezone" 20 70 10 $(awk '/^[^#]/ {print $3 " " $3}' /usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)

HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname" 10 60 "artix" 3>&1 1>&2 2>&3)
ROOT_PW=$(get_password "Root Password")
USERNAME=$(whiptail --title "$TITLE" --inputbox "Username" 10 60 "user" 3>&1 1>&2 2>&3)
USER_PW=$(get_password "User Password")

DE_CHOICE=$(whiptail --title "$TITLE" --menu "Desktop Environment" 20 70 6 "Plasma" "KDE Plasma" "XFCE" "XFCE4" "MATE" "MATE" "LXQt" "LXQt" "Moksha" "Moksha" "None" "CLI Only" 3>&1 1>&2 2>&3)

# --- STAGE 2: DISK & PARTITIONING ---
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
    btrfs) mkfs.btrfs -f "$ROOT" ;;
    xfs) mkfs.xfs -f "$ROOT" ;;
    f2fs) mkfs.f2fs -f "$ROOT" ;;
esac

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- STAGE 3: SWAP & BASESTRAP ---
if [[ "$SWAP_CHOICE" == "Swapfile" || "$SWAP_CHOICE" == "Both" ]]; then
    echo "Creating Swapfile..."
    if [[ "$FS_CHOICE" == "btrfs" ]]; then
        truncate -s 0 /mnt/swapfile
        chattr +C /mnt/swapfile
        fallocate -l 4G /mnt/swapfile
    else
        dd if=/dev/zero of=/mnt/swapfile bs=1M count=4096 status=progress
    fi
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
fi

# Packages - Note: Added wpa_supplicant for better WiFi support
BASE_PKGS="base base-devel linux linux-firmware intel-ucode amd-ucode dinit elogind-dinit dbus-dinit doas vi networkmanager networkmanager-dinit wpa_supplicant grub efibootmgr ntfs-3g dosfstools mtools libnewt mesa xorg-server"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils pavucontrol"
FS_PKGS=""
[[ "$FS_CHOICE" == "btrfs" ]] && FS_PKGS="btrfs-progs"
[[ "$FS_CHOICE" == "xfs" ]]   && FS_PKGS="xfsprogs"
[[ "$FS_CHOICE" == "f2fs" ]]  && FS_PKGS="f2fs-tools"
SWAP_PKGS=""
[[ "$SWAP_CHOICE" == "Zram" || "$SWAP_CHOICE" == "Both" ]] && SWAP_PKGS="zramen zramen-dinit"

basestrap /mnt $BASE_PKGS $AUDIO_PKGS $FS_PKGS $SWAP_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab

[[ -f /mnt/swapfile ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- STAGE 4: CONFIGURATION ---
echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
artix-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
artix-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
artix-chroot /mnt hwclock --systohc

echo "$HOSTNAME" > /mnt/etc/hostname
echo "root:$ROOT_PW" | artix-chroot /mnt chpasswd
artix-chroot /mnt useradd -m -G wheel,audio,video,storage "$USERNAME"
echo "$USERNAME:$USER_PW" | artix-chroot /mnt chpasswd

# Security & Sudo Compatibility
echo "permit persist :wheel" > /mnt/etc/doas.conf
artix-chroot /mnt ln -sf /usr/bin/doas /usr/bin/sudo

# Audio Fix: Create autostart for Pipewire
artix-chroot /mnt bash -c "cat > /etc/profile.d/pipewire-start.sh <<EOF
if [ -n \"\\\$DISPLAY\" ] || [ -n \"\\\$WAYLAND_DISPLAY\" ]; then
    pgrep -x pipewire > /dev/null || pipewire &
    pgrep -x pipewire-pulse > /dev/null || pipewire-pulse &
    pgrep -x wireplumber > /dev/null || wireplumber &
fi
EOF"

# Install DE
case $DE_CHOICE in
    Plasma) artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm-dinit ;;
    XFCE)   artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies lightdm-dinit ;;
    MATE)   artix-chroot /mnt pacman -S --noconfirm mate mate-extra lightdm-dinit ;;
    LXQt)   artix-chroot /mnt pacman -S --noconfirm lxqt sddm-dinit ;;
    Moksha) artix-chroot /mnt pacman -S --noconfirm moksha-artix lightdm-dinit ;;
esac

# Services (The Dinit way)
artix-chroot /mnt mkdir -p /etc/dinit.d/boot.d
DM=""
[[ "$DE_CHOICE" =~ Plasma|LXQt ]] && DM="sddm"
[[ "$DE_CHOICE" =~ XFCE|MATE|Moksha ]] && DM="lightdm"

# Note: In Artix Dinit, the NetworkManager service is usually 'networkmanager' (lowercase)
for svc in dbus networkmanager elogind zramen $DM; do
    [ -f "/mnt/etc/dinit.d/$svc" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done

# Bootloader
artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# --- FINISH ---
umount -R /mnt
sync
whiptail --title "$TITLE" --msgbox "Installation complete! WiFi and Audio auto-config applied." 10 60
reboot
