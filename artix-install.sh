#!/bin/bash
set -e
set -o pipefail

[ "$EUID" -ne 0 ] && echo "Please run as root." && exit 1

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
rm -f /mnt/var/lib/pacman/db.lck 2>/dev/null

clear
TITLE="Artix Master Installer (Dinit Fixed)"

# --- UPDATE LIVE KEYRING ---
pacman -Sy artix-keyring --noconfirm
pacman-key --init
pacman-key --populate artix

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
    local input="$1"; [ -z "$input" ] && exit 1; echo "$input"
}

# --- STAGE 1: USER INPUTS ---
DISK=$(lsblk -dpnoNAME,SIZE | grep -v loop | \
    whiptail --title "$TITLE" --menu "Select installation disk" 20 70 10 \
    $(lsblk -dpnoNAME,SIZE | grep -v loop | awk '{print $1 " " $2}') 3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

FS_CHOICE=$(whiptail --title "$TITLE" --menu "Root filesystem" 15 60 4 \
"ext4" "Standard" \
"btrfs" "Btrfs" \
"xfs" "XFS" \
"f2fs" "F2FS" 3>&1 1>&2 2>&3)

SWAP_CHOICE=$(whiptail --title "$TITLE" --menu "Swap configuration" 15 60 4 \
"Zram" "Use zramen" \
"Swapfile" "Disk swapfile" \
"Both" "Zram + swapfile" \
"None" "No swap" 3>&1 1>&2 2>&3)

if [[ "$SWAP_CHOICE" == "Swapfile" || "$SWAP_CHOICE" == "Both" ]]; then
    SWAP_SIZE=$(whiptail --title "$TITLE" --inputbox "Swapfile size in MB" 10 60 "4096" 3>&1 1>&2 2>&3)
    SWAP_SIZE=$(validate_input "$SWAP_SIZE")
fi

LOCALE=$(whiptail --title "$TITLE" --menu "Locale" 20 70 10 \
$(grep "UTF-8" /usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)

TIMEZONE=$(whiptail --title "$TITLE" --menu "Timezone" 20 70 10 \
$(awk '/^[^#]/ {print $3 " " $3}' /usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)

HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname" 10 60 "artix" 3>&1 1>&2 2>&3)
ROOT_PW=$(get_password "Root password")
USERNAME=$(whiptail --title "$TITLE" --inputbox "Username" 10 60 "user" 3>&1 1>&2 2>&3)
USER_PW=$(get_password "User password")

DE_CHOICE=$(whiptail --title "$TITLE" --menu "Environment" 20 70 10 \
"Plasma" "KDE Plasma" \
"XFCE" "XFCE4" \
"LXQt" "LXQt" \
"i3" "i3wm" \
"XMonad" "XMonad" \
"WindowMaker" "WindowMaker" \
"Moksha" "Moksha desktop" 3>&1 1>&2 2>&3)

# --- STAGE 2: DISK PARTITION + FORMAT ---
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
[[ "$DISK" =~ [0-9]$ ]] && P="p" || P=""
EFI="${DISK}${P}1"; ROOT="${DISK}${P}2"

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

# --- STAGE 3: SWAP ---
if [[ "$SWAP_CHOICE" == "Swapfile" || "$SWAP_CHOICE" == "Both" ]]; then
    if [[ "$FS_CHOICE" == "btrfs" ]]; then
        truncate -s 0 /mnt/swapfile
        chattr +C /mnt/swapfile
        fallocate -l "${SWAP_SIZE}M" /mnt/swapfile
    else
        dd if=/dev/zero of=/mnt/swapfile bs=1M count="$SWAP_SIZE" status=progress
    fi
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
fi

[[ "$SWAP_CHOICE" =~ Zram|Both ]] && ZRAM_PKGS="zramen zramen-dinit" || ZRAM_PKGS=""

# --- STAGE 4: BASESTRAP ---
GPU_PKGS="mesa vulkan-intel xf86-video-intel"
lspci | grep -qi nvidia && GPU_PKGS="nvidia nvidia-utils nvidia-settings"
lspci | grep -qi amd && GPU_PKGS="mesa xf86-video-amdgpu vulkan-mesa-layers"

BASE_PKGS="base base-devel linux linux-firmware intel-ucode amd-ucode dinit elogind-dinit dbus-dinit doas vi networkmanager networkmanager-dinit wpa_supplicant grub efibootmgr ntfs-3g dosfstools mtools libnewt xorg-server xorg-xinit haveged haveged-dinit xdg-user-dirs dbus-x11 rtkit"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils pavucontrol"

basestrap /mnt $BASE_PKGS $AUDIO_PKGS $GPU_PKGS $ZRAM_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab
[[ "$SWAP_CHOICE" == "Swapfile" || "$SWAP_CHOICE" == "Both" ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
