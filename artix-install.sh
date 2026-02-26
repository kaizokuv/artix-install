#!/bin/bash
set -e
set -o pipefail

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./installer.sh)"
    exit 1
fi

clear
TITLE="Artix Linux Installer (Dinit)"

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
    if [ -z "$input" ]; then
        whiptail --title "$TITLE" --msgbox "Input cannot be empty. Installation cancelled." 10 60
        exit 1
    fi
    echo "$input"
}

# --- STAGE 1: GATHER ALL USER INPUTS (FRONT-LOADING) ---

# 1. Disk Selection
DISK=$(lsblk -dpnoNAME,SIZE | grep -v loop | whiptail \
--title "$TITLE" \
--menu "Select installation disk" 20 70 10 \
$(lsblk -dpnoNAME,SIZE | grep -v loop | awk '{print $1 " " $2}') \
3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

# 2. Filesystem & Swap
FS_CHOICE=$(whiptail --title "$TITLE" --menu "Select Root File System" 15 60 4 \
"ext4" "Standard Ext4" \
"btrfs" "BTRFS (Modern, Snapshots)" \
"xfs" "XFS (High Performance)" \
"f2fs" "F2FS (Optimized for SSD/NVMe)" 3>&1 1>&2 2>&3)

SWAPSIZE=$(whiptail --title "$TITLE" --inputbox "Enter swap size (e.g., 8G or 4096M). Enter 0 for none." 10 60 "8G" 3>&1 1>&2 2>&3)

# 3. Locale & Timezone (Reading from LIVE environment to prevent chroot errors)
LOCALE=$(whiptail --title "$TITLE" --menu "Select your locale" 20 70 10 \
$(grep "UTF-8" /usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
LOCALE=$(validate_input "$LOCALE")

TIMEZONE=$(whiptail --title "$TITLE" --menu "Select your timezone" 20 70 10 \
$(awk '/^[^#]/ {print $3 " " $3}' /usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)
TIMEZONE=$(validate_input "$TIMEZONE")

# 4. Networking & Users
HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Enter hostname" 10 60 "artix-pc" 3>&1 1>&2 2>&3)
HOSTNAME=$(validate_input "$HOSTNAME")

ROOT_PW=$(get_password "Set Root Password")

USERNAME=$(whiptail --title "$TITLE" --inputbox "Enter username" 10 60 "user" 3>&1 1>&2 2>&3)
USERNAME=$(validate_input "$USERNAME")
USER_PW=$(get_password "Set password for $USERNAME")

# 5. Desktop Environment / Window Manager
DESKTOP_TYPE=$(whiptail --title "$TITLE" --menu "Select Desktop or Window Manager" 20 70 6 \
"DE" "Desktop Environment (Plasma, XFCE, etc)" \
"WM" "Window Manager Only (i3, XMonad)" 3>&1 1>&2 2>&3)

if [[ "$DESKTOP_TYPE" == "DE" ]]; then
    DE_CHOICE=$(whiptail --title "$TITLE" --menu "Select Desktop" 20 70 6 \
    "Plasma" "KDE Plasma" "XFCE" "XFCE4" "MATE" "MATE" "LXQt" "LXQt" "Moksha" "Moksha" 3>&1 1>&2 2>&3)
else
    DE_CHOICE=$(whiptail --title "$TITLE" --menu "Select WM" 20 70 6 \
    "i3" "i3" "XMonad" "XMonad" "WindowMaker" "WindowMaker" 3>&1 1>&2 2>&3)
fi

# Final Confirmation
whiptail --title "$TITLE" --yesno "Ready to install. ALL DATA ON $DISK WILL BE WIPED. Proceed?" 10 60 || exit 1

# --- STAGE 2: SYSTEM PREPARATION & PARTITIONING ---
echo "Starting installation on $DISK..."

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK"

# Create 1GB EFI and Remainder Root
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

# Formatting
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

# --- STAGE 3: SWAPFILE ---
SWAP_MB=0
if [[ "$SWAPSIZE" =~ G$ ]]; then SWAP_MB=$(( ${SWAPSIZE%G} * 1024 ))
elif [[ "$SWAPSIZE" =~ M$ ]]; then SWAP_MB=${SWAPSIZE%M}
fi

if [[ "$SWAP_MB" -gt 0 ]]; then
    echo "Configuring Swap..."
    if [[ "$FS_CHOICE" == "btrfs" ]]; then
        truncate -s 0 /mnt/swapfile
        chattr +C /mnt/swapfile
        fallocate -l "${SWAP_MB}M" /mnt/swapfile
    else
        dd if=/dev/zero of=/mnt/swapfile bs=1M count=$SWAP_MB status=progress
    fi
    chmod 0600 /mnt/swapfile
    mkswap /mnt/swapfile
    swapon /mnt/swapfile
fi

# --- STAGE 4: BASESTRAP ---
echo "Downloading and installing base system (this may take a while)..."
BASE_PKGS="base base-devel linux linux-firmware intel-ucode amd-ucode dinit elogind-dinit dbus-dinit doas vi networkmanager networkmanager-dinit grub efibootmgr ntfs-3g dosfstools mtools mesa xorg-server"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils pavucontrol"
FS_PKGS=""
[[ "$FS_CHOICE" == "btrfs" ]] && FS_PKGS="btrfs-progs"
[[ "$FS_CHOICE" == "xfs" ]] && FS_PKGS="xfsprogs"
[[ "$FS_CHOICE" == "f2fs" ]] && FS_PKGS="f2fs-tools"

basestrap /mnt $BASE_PKGS $AUDIO_PKGS $FS_PKGS

fstabgen -U /mnt >> /mnt/etc/fstab
[[ "$SWAP_MB" -gt 0 ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- STAGE 5: SYSTEM CONFIGURATION ---
echo "Configuring localization, users, and bootloader..."

# Time and Locale
echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
artix-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
artix-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
artix-chroot /mnt hwclock --systohc

# Identity
echo "$HOSTNAME" > /mnt/etc/hostname
echo "root:$ROOT_PW" | artix-chroot /mnt chpasswd
artix-chroot /mnt useradd -m -G wheel,audio,video,storage "$USERNAME"
echo "$USERNAME:$USER_PW" | artix-chroot /mnt chpasswd

# Security (Doas + Sudo Link)
echo "permit persist :wheel" > /mnt/etc/doas.conf
artix-chroot /mnt chown root:root /etc/doas.conf
artix-chroot /mnt chmod 0400 /etc/doas.conf
artix-chroot /mnt ln -sf /usr/bin/doas /usr/bin/sudo

# Desktop/WM Installation
echo "Installing Desktop Environment: $DE_CHOICE..."
case $DE_CHOICE in
    Plasma) artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm-dinit ;;
    XFCE)   artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies lightdm-dinit ;;
    MATE)   artix-chroot /mnt pacman -S --noconfirm mate mate-extra lightdm-dinit ;;
    LXQt)   artix-chroot /mnt pacman -S --noconfirm lxqt sddm-dinit ;;
    Moksha) artix-chroot /mnt pacman -S --noconfirm moksha-artix lightdm-dinit ;;
    i3)     artix-chroot /mnt pacman -S --noconfirm i3-wm dmenu lightdm-dinit xterm ;;
    XMonad) artix-chroot /mnt pacman -S --noconfirm xmonad xmobar lightdm-dinit xterm ;;
    WindowMaker) artix-chroot /mnt pacman -S --noconfirm windowmaker lightdm-dinit xterm ;;
esac

# Services (Dinit)
artix-chroot /mnt mkdir -p /etc/dinit.d/boot.d
for svc in dbus networkmanager elogind; do
    [ -f "/mnt/etc/dinit.d/$svc" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done

# Display Manager Service
DM="lightdm"
[[ "$DE_CHOICE" == "Plasma" || "$DE_CHOICE" == "LXQt" ]] && DM="sddm"
[ -f "/mnt/etc/dinit.d/$DM" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$DM /etc/dinit.d/boot.d/

# Bootloader
artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# --- STAGE 6: CLEANUP ---
umount -R /mnt
sync

if whiptail --title "$TITLE" --yesno "Installation complete! Reboot now?" 10 60; then
    reboot
fi
