#!/bin/bash
set -e
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

clear
TITLE="Artix Master Installer (Dinit Optimized)"

# --- HELPERS ---
get_password() {
    local prompt="$1"; local pw=""
    while [ -z "$pw" ]; do
        pw=$(whiptail --title "$TITLE" --passwordbox "$prompt" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && exit 1
    done
    echo "$pw"
}

validate_input() { local input="$1"; [ -z "$input" ] && exit 1; echo "$input"; }

# --- STAGE 1: USER INPUTS ---
DISK=$(lsblk -dpnoNAME,SIZE | grep -v loop | whiptail --title "$TITLE" --menu "Select Disk" 20 70 10 $(lsblk -dpnoNAME,SIZE | grep -v loop | awk '{print $1 " " $2}') 3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

FS_CHOICE=$(whiptail --title "$TITLE" --menu "Root Filesystem" 15 60 4 "ext4" "Standard Ext4" "btrfs" "B-Tree Filesystem" "xfs" "XFS" "f2fs" "Flash-Friendly" 3>&1 1>&2 2>&3)
SWAP_CHOICE=$(whiptail --title "$TITLE" --menu "Swap Configuration" 15 60 4 "Zram" "Use zramen" "Swapfile" "Disk Swapfile" "Both" "Zram + Swapfile" "None" "No Swap" 3>&1 1>&2 2>&3)

# Swap size if needed
if [[ "$SWAP_CHOICE" == "Swapfile" || "$SWAP_CHOICE" == "Both" ]]; then
    SWAP_SIZE=$(whiptail --title "$TITLE" --inputbox "Enter swapfile size in MB (e.g., 4096)" 10 60 "4096" 3>&1 1>&2 2>&3)
    SWAP_SIZE=$(validate_input "$SWAP_SIZE")
fi

LOCALE=$(whiptail --title "$TITLE" --menu "Select locale" 20 70 10 $(grep "UTF-8" /usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
TIMEZONE=$(whiptail --title "$TITLE" --menu "Select timezone" 20 70 10 $(awk '/^[^#]/ {print $3 " " $3}' /usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)

HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname" 10 60 "artix" 3>&1 1>&2 2>&3)
ROOT_PW=$(get_password "Root Password")
USERNAME=$(whiptail --title "$TITLE" --inputbox "Username" 10 60 "user" 3>&1 1>&2 2>&3)
USER_PW=$(get_password "User Password")

# DE first, WM second
DE_CHOICE=$(whiptail --title "$TITLE" --menu "Desktop Environment" 20 70 10 \
"Plasma" "KDE Plasma" \
"XFCE" "XFCE4" \
"LXQt" "LXQt" \
"Moksha" "Moksha Desktop" 3>&1 1>&2 2>&3)

WM_CHOICE=$(whiptail --title "$TITLE" --menu "Window Manager" 20 70 10 \
"i3" "i3wm" \
"XMonad" "XMonad" \
"WindowMaker" "WindowMaker" 3>&1 1>&2 2>&3)

# --- STAGE 2: DISK PARTITION & FORMAT ---
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
mount "$ROOT" /mnt; mkdir -p /mnt/boot; mount "$EFI" /mnt/boot

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

# --- STAGE 4: BASE & AUDIO PACKAGES ---
GPU_PKGS="mesa vulkan-intel xf86-video-intel"
lspci | grep -i "nvidia" &>/dev/null && GPU_PKGS="nvidia nvidia-utils nvidia-settings"
lspci | grep -i "amd" &>/dev/null && GPU_PKGS="mesa xf86-video-amdgpu vulkan-mesa-layers"

BASE_PKGS="base base-devel linux linux-firmware intel-ucode amd-ucode dinit elogind-dinit dbus-dinit doas vi networkmanager networkmanager-dinit wpa_supplicant grub efibootmgr ntfs-3g dosfstools mtools libnewt xorg-server xorg-xinit haveged haveged-dinit xdg-user-dirs dbus-x11 rtkit rtkit-dinit"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils pavucontrol"

basestrap /mnt $BASE_PKGS $AUDIO_PKGS $GPU_PKGS $ZRAM_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab
[[ "$SWAP_CHOICE" == "Swapfile" || "$SWAP_CHOICE" == "Both" ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- STAGE 5: CONFIG & OPTIMIZATIONS ---
sed -i 's/#Color/Color\nILoveCandy/' /mnt/etc/pacman.conf
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /mnt/etc/pacman.conf
if ! grep -q "\[universe\]" /mnt/etc/pacman.conf; then
    cat >> /mnt/etc/pacman.conf <<EOF

[universe]
Server = https://universe.artixlinux.org/\$arch
EOF
fi

echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
artix-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
artix-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
artix-chroot /mnt hwclock --systohc
echo "$HOSTNAME" > /mnt/etc/hostname

# Users
echo "root:$ROOT_PW" | artix-chroot /mnt chpasswd
artix-chroot /mnt useradd -m -G wheel,audio,video,storage "$USERNAME"
echo "$USERNAME:$USER_PW" | artix-chroot /mnt chpasswd
echo "permit persist :wheel" > /mnt/etc/doas.conf
artix-chroot /mnt ln -sf /usr/bin/doas /usr/bin/sudo
artix-chroot /mnt xdg-user-dirs-update

echo "export HISTCONTROL=ignoreboth" >> /mnt/home/$USERNAME/.bashrc
echo "export HISTSIZE=10000" >> /mnt/home/$USERNAME/.bashrc
echo "alias sudo='doas'" >> /mnt/home/$USERNAME/.bashrc
artix-chroot /mnt chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc

# Pipewire Fix
artix-chroot /mnt bash -c "cat > /etc/profile.d/pipewire-start.sh << 'EOF'
[ \"\$UID\" -lt 1000 ] && return
if [ -z \"\$XDG_RUNTIME_DIR\" ]; then
    export XDG_RUNTIME_DIR=\"/run/user/\$(id -u)\"
fi
if [ -z \"\$DBUS_SESSION_BUS_ADDRESS\" ]; then
    eval \$(dbus-launch --sh-syntax --exit-with-session)
fi
pgrep -x pipewire > /dev/null || pipewire &
pgrep -x pipewire-pulse > /dev/null || pipewire-pulse &
pgrep -x wireplumber > /dev/null || wireplumber &
EOF"
chmod +x /mnt/etc/profile.d/pipewire-start.sh

# --- STAGE 6: DE/WM INSTALL ---
case $DE_CHOICE in
    Plasma) artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm-dinit xdg-desktop-portal-kde plasma-pa ;;
    XFCE)   artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies lightdm-dinit lightdm-gtk-greeter xdg-desktop-portal-gtk ;;
    LXQt)   artix-chroot /mnt pacman -S --noconfirm lxqt sddm-dinit ;;
    Moksha) artix-chroot /mnt pacman -S --noconfirm moksha-artix lightdm-dinit lightdm-gtk-greeter ;;
esac

case $WM_CHOICE in
    i3)     artix-chroot /mnt pacman -S --noconfirm i3-wm dmenu lightdm-dinit lightdm-gtk-greeter xterm ;;
    XMonad) artix-chroot /mnt pacman -S --noconfirm xmonad xmonad-contrib xmobar dmenu lightdm-dinit lightdm-gtk-greeter xterm ;;
    WindowMaker) artix-chroot /mnt pacman -S --noconfirm windowmaker lightdm-dinit lightdm-gtk-greeter xterm ;;
esac

# --- STAGE 7: DINIT SERVICES ---
artix-chroot /mnt mkdir -p /etc/dinit.d/boot.d
DM="lightdm"
[[ "$DE_CHOICE" =~ Plasma|LXQt ]] && DM="sddm"

for svc in dbus NetworkManager elogind haveged rtkit $DM; do
    [ -f "/mnt/etc/dinit.d/$svc" ] && artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
done
[[ "$SWAP_CHOICE" =~ Zram|Both ]] && artix-chroot /mnt ln -sf /etc/dinit.d/zramen /etc/dinit.d/boot.d/

# --- STAGE 8: BOOTLOADER ---
artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# --- FINISH ---
umount -R /mnt
whiptail --title "$TITLE" --msgbox "System installed and optimized! Rebooting..." 10 60
reboot
