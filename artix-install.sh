#!/bin/bash
set -e
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

clear
TITLE="Artix Linux Master Installer (V3 - Fast Boot Edition)"

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
DISK=$(lsblk -dpnoNAME,SIZE | grep -v loop | whiptail --title "$TITLE" --menu "Select Disk" 20 70 10 $(lsblk -dpnoNAME,SIZE | grep -v loop | awk '{print $1 " " $2}') 3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

FS_CHOICE=$(whiptail --title "$TITLE" --menu "Root Filesystem" 15 60 4 "ext4" "Standard Ext4" "btrfs" "B-Tree Filesystem" "xfs" "XFS" "f2fs" "Flash-Friendly" 3>&1 1>&2 2>&3)

SWAP_CHOICE=$(whiptail --title "$TITLE" --menu "Swap Configuration" 15 60 4 "Zram" "Use zramen" "Swapfile" "4GB Swapfile" "Both" "Zram + 4GB Swapfile" "None" "No Swap" 3>&1 1>&2 2>&3)

LOCALE=$(whiptail --title "$TITLE" --menu "Select locale" 20 70 10 $(grep "UTF-8" /usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
TIMEZONE=$(whiptail --title "$TITLE" --menu "Select timezone" 20 70 10 $(awk '/^[^#]/ {print $3 " " $3}' /usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)

HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname" 10 60 "artix" 3>&1 1>&2 2>&3)
ROOT_PW=$(get_password "Root Password")
USERNAME=$(whiptail --title "$TITLE" --inputbox "Username" 10 60 "user" 3>&1 1>&2 2>&3)
USER_PW=$(get_password "User Password")

# RESTORED WM SELECTION
DE_CHOICE=$(whiptail --title "$TITLE" --menu "Desktop/Window Manager" 20 70 10 \
"Plasma" "KDE Plasma" \
"XFCE" "XFCE4" \
"i3" "i3 Window Manager" \
"XMonad" "XMonad" \
"WindowMaker" "WindowMaker" \
"Moksha" "Moksha Desktop" \
"None" "CLI Only" 3>&1 1>&2 2>&3)

# --- STAGE 2: DISK OPS ---
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

GPU_PKGS="mesa vulkan-intel xf86-video-intel"
if lspci | grep -iI "nvidia" > /dev/null; then
    GPU_PKGS="nvidia nvidia-utils nvidia-settings"
elif lspci | grep -iI "amd" > /dev/null; then
    GPU_PKGS="mesa xf86-video-amdgpu vulkan-mesa-layers"
fi

# Added 'haveged' for faster boot (entropy)
BASE_PKGS="base base-devel linux linux-firmware intel-ucode amd-ucode dinit elogind-dinit dbus-dinit doas vi networkmanager networkmanager-dinit wpa_supplicant grub efibootmgr ntfs-3g dosfstools mtools libnewt xorg-server xorg-xinit haveged haveged-dinit"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils pavucontrol"
FS_PKGS=""
[[ "$FS_CHOICE" == "btrfs" ]] && FS_PKGS="btrfs-progs"
[[ "$FS_CHOICE" == "xfs" ]]   && FS_PKGS="xfsprogs"
[[ "$FS_CHOICE" == "f2fs" ]]  && FS_PKGS="f2fs-tools"
SWAP_PKGS=""
[[ "$SWAP_CHOICE" == "Zram" || "$SWAP_CHOICE" == "Both" ]] && SWAP_PKGS="zramen zramen-dinit"

basestrap /mnt $BASE_PKGS $AUDIO_PKGS $FS_PKGS $SWAP_PKGS $GPU_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab

# --- STAGE 4: CONFIG ---
echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
artix-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
artix-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
artix-chroot /mnt hwclock --systohc
echo "$HOSTNAME" > /mnt/etc/hostname
echo "root:$ROOT_PW" | artix-chroot /mnt chpasswd
artix-chroot /mnt useradd -m -G wheel,audio,video,storage "$USERNAME"
echo "$USERNAME:$USER_PW" | artix-chroot /mnt chpasswd
echo "permit persist :wheel" > /mnt/etc/doas.conf
artix-chroot /mnt ln -sf /usr/bin/doas /usr/bin/sudo

# Audio Fix
artix-chroot /mnt bash -c "cat > /etc/profile.d/pipewire-start.sh <<EOF
if [ -n \"\\\$DISPLAY\" ] || [ -n \"\\\$WAYLAND_DISPLAY\" ]; then
    pgrep -x pipewire > /dev/null || pipewire &
    pgrep -x pipewire-pulse > /dev/null || pipewire-pulse &
    pgrep -x wireplumber > /dev/null || wireplumber &
fi
EOF"

# Zram Fix: Create a default config so the service doesn't fail
if [[ "$SWAP_CHOICE" == "Zram" || "$SWAP_CHOICE" == "Both" ]]; then
    artix-chroot /mnt bash -c "echo 'MAX_SIZE=2048' > /etc/default/zramen"
fi

# Install DE/WM
case $DE_CHOICE in
    Plasma) artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm-dinit ;;
    XFCE)   artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies lightdm-dinit ;;
    i3)     artix-chroot /mnt pacman -S --noconfirm i3-wm dmenu lightdm-dinit xterm ;;
    XMonad) artix-chroot /mnt pacman -S --noconfirm xmonad xmobar lightdm-dinit xterm dmenu ;;
    WindowMaker) artix-chroot /mnt pacman -S --noconfirm windowmaker lightdm-dinit xterm ;;
    Moksha) artix-chroot /mnt pacman -S --noconfirm moksha-artix lightdm-dinit ;;
esac

# Services
artix-chroot /mnt mkdir -p /etc/dinit.d/boot.d
DM=""
[[ "$DE_CHOICE" =~ Plasma ]] && DM="sddm"
[[ "$DE_CHOICE" =~ XFCE|i3|XMonad|WindowMaker|Moksha ]] && DM="lightdm"

# Added 'haveged' to service loop for fast boot
for svc in dbus NetworkManager elogind zramen haveged $DM; do
    [ -f "/mnt/etc/dinit.d/$svc" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done

# Bootloader
artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

umount -R /mnt
whiptail --title "$TITLE" --msgbox "Done! Fast-boot entropy and Zram fixes applied." 10 60
reboot
