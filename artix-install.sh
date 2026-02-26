#!/bin/bash
set -e
set -o pipefail

# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

clear
TITLE="Artix Master Installer (Plasma Audio Fix)"

# --- HELPERS ---
get_confirmed_password() {
    local prompt="$1"
    local pw1 pw2
    while true; do
        pw1=$(whiptail --title "$TITLE" --passwordbox "$prompt" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && exit 1
        pw2=$(whiptail --title "$TITLE" --passwordbox "Confirm $prompt" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && exit 1
        if [ "$pw1" = "$pw2" ]; then
            echo "$pw1"
            return
        fi
        whiptail --title "$TITLE" --msgbox "Passwords do not match. Try again." 8 50
    done
}

# --- STAGE 1: INPUTS ---

# awk prints name and size on separate lines so whiptail gets them as distinct args
mapfile -t DISKLIST < <(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1; print $2}')
DISK=$(whiptail --title "$TITLE" --menu "Select Disk" 20 70 10 \
    "${DISKLIST[@]}" 3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

FS_CHOICE=$(whiptail --title "$TITLE" --menu "Root Filesystem" 15 60 4 \
    "ext4"  "Standard Ext4" \
    "btrfs" "B-Tree Filesystem" \
    "xfs"   "XFS" \
    "f2fs"  "Flash-Friendly" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1

SWAP_CHOICE=$(whiptail --title "$TITLE" --menu "Swap Configuration" 15 60 4 \
    "Zram"     "Use zramen" \
    "Swapfile" "Disk Swapfile" \
    "Both"     "Zram + Swapfile" \
    "None"     "No Swap" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1

LOCALE=$(whiptail --title "$TITLE" --menu "Select locale" 20 70 10 \
    $(grep "UTF-8" /usr/share/i18n/SUPPORTED | awk '{print $1 " " $1}') 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1

TIMEZONE=$(whiptail --title "$TITLE" --menu "Select timezone" 20 70 10 \
    $(awk '/^[^#]/ {print $3 " " $3}' /usr/share/zoneinfo/zone.tab | sort) 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1

HOSTNAME=""
while [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9\-]+$ ]]; do
    HOSTNAME=$(whiptail --title "$TITLE" --inputbox \
        "Hostname (letters, numbers, hyphens only)" 10 60 "artix" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1
done

ROOT_PW=$(get_confirmed_password "Root Password")

USERNAME=""
while [[ ! "$USERNAME" =~ ^[a-z][a-z0-9_\-]*$ ]]; do
    USERNAME=$(whiptail --title "$TITLE" --inputbox \
        "Username (lowercase letters, numbers, _ or - only)" 10 60 "user" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1
done

USER_PW=$(get_confirmed_password "User Password")

DE_CHOICE=$(whiptail --title "$TITLE" --menu "Desktop Environment" 20 70 10 \
    "Plasma"      "KDE Plasma" \
    "XFCE"        "XFCE4" \
    "LXQt"        "LXQt" \
    "i3"          "i3wm" \
    "XMonad"      "XMonad" \
    "WindowMaker" "WindowMaker" \
    "Moksha"      "Moksha" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1

# --- STAGE 2: DISK OPERATIONS ---
umount -R /mnt 2>/dev/null || true
mkdir -p /mnt

wipefs -af "$DISK"
fdisk "$DISK" << EOF
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
case "$FS_CHOICE" in
    ext4)  mkfs.ext4  -F "$ROOT" ;;
    btrfs) mkfs.btrfs -f "$ROOT" ;;
    xfs)   mkfs.xfs   -f "$ROOT" ;;
    f2fs)  mkfs.f2fs  -f "$ROOT" ;;
esac

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- STAGE 3: SWAP SETUP ---
rm -f /mnt/swapfile
if [[ "$SWAP_CHOICE" == "Swapfile" || "$SWAP_CHOICE" == "Both" ]]; then
    if [[ "$FS_CHOICE" == "btrfs" ]]; then
        # CoW must be disabled before allocation or the swapfile won't activate
        truncate -s 0 /mnt/swapfile
        chattr +C /mnt/swapfile
        fallocate -l 4G /mnt/swapfile
    else
        dd if=/dev/zero of=/mnt/swapfile bs=1M count=4096 status=progress
    fi
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
fi

# --- STAGE 4: PACKAGE SELECTION ---

# elif prevents AMD from overwriting NVIDIA on hybrid GPU systems
if lspci | grep -qi "nvidia"; then
    GPU_PKGS="nvidia nvidia-utils nvidia-settings"
elif lspci | grep -qi "amd"; then
    GPU_PKGS="mesa xf86-video-amdgpu vulkan-mesa-layers"
else
    GPU_PKGS="mesa vulkan-intel xf86-video-intel"
fi

# rtkit-dinit does not exist — rtkit ships its own dinit service file
BASE_PKGS="base base-devel linux linux-firmware intel-ucode amd-ucode \
    dinit elogind-dinit dbus-dinit doas vi \
    networkmanager networkmanager-dinit wpa_supplicant \
    grub efibootmgr ntfs-3g dosfstools mtools \
    libnewt xorg-server xorg-xinit \
    haveged haveged-dinit xdg-user-dirs \
    dbus rtkit"

AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils pavucontrol"

# --- STAGE 5: BASESTRAP ---
basestrap /mnt $BASE_PKGS $AUDIO_PKGS $GPU_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab

# --- STAGE 6: CHROOT CONFIGURATION ---
# Passwords are base64-encoded so special chars ($, !, \) don't break anything
ROOT_PW_B64=$(printf '%s' "$ROOT_PW" | base64)
USER_PW_B64=$(printf '%s' "$USER_PW" | base64)

cat > /mnt/root/install_env << EOF
CONFIGURE_ROOT_PW_B64=${ROOT_PW_B64}
CONFIGURE_USER_PW_B64=${USER_PW_B64}
CONFIGURE_USERNAME=${USERNAME}
CONFIGURE_LOCALE=${LOCALE}
CONFIGURE_TIMEZONE=${TIMEZONE}
CONFIGURE_HOSTNAME=${HOSTNAME}
EOF
chmod 600 /mnt/root/install_env

cat > /mnt/root/configure.sh << 'CHROOT'
#!/bin/bash
set -e
source /root/install_env

ROOT_PW=$(printf '%s' "$CONFIGURE_ROOT_PW_B64" | base64 -d)
USER_PW=$(printf '%s' "$CONFIGURE_USER_PW_B64" | base64 -d)

echo "${CONFIGURE_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${CONFIGURE_LOCALE}" > /etc/locale.conf
ln -sf "/usr/share/zoneinfo/${CONFIGURE_TIMEZONE}" /etc/localtime
hwclock --systohc

echo "${CONFIGURE_HOSTNAME}" > /etc/hostname

printf '%s:%s\n' "root" "$ROOT_PW" | chpasswd
useradd -m -G wheel,audio,video,storage "${CONFIGURE_USERNAME}"
printf '%s:%s\n' "${CONFIGURE_USERNAME}" "$USER_PW" | chpasswd

echo "permit persist :wheel" > /etc/doas.conf
ln -sf /usr/bin/doas /usr/bin/sudo

xdg-user-dirs-update
rm /root/install_env
CHROOT

chmod +x /mnt/root/configure.sh
artix-chroot /mnt /root/configure.sh
rm /mnt/root/configure.sh

# --- STAGE 7: AUDIO SETUP ---
# .xprofile is skipped by SDDM on Wayland (Plasma default) — use Plasma autostart-scripts
# which run on both X11 and Wayland. Keep .xprofile + dinit services as fallback.

mkdir -p /mnt/home/"$USERNAME"

# chown by name fails outside chroot — resolve numeric UID/GID from chroot passwd
USER_UID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f3)
USER_GID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f4)

# Plasma autostart script (works on Wayland + X11)
mkdir -p /mnt/home/"$USERNAME"/.config/autostart-scripts
cat > /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh << 'AUTOSTART'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
AUTOSTART
chmod +x /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh
chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.config/autostart-scripts

# .xprofile fallback for non-Plasma / X11 DEs
cat > /mnt/home/"$USERNAME"/.xprofile << 'XPROFILE'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
XPROFILE
chown "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.xprofile

# User dinit service files (TTY login fallback)
mkdir -p /mnt/home/"$USERNAME"/.config/dinit.d

cat > /mnt/home/"$USERNAME"/.config/dinit.d/pipewire << 'DSVC'
type = process
command = /usr/bin/pipewire
restart = true
DSVC

cat > /mnt/home/"$USERNAME"/.config/dinit.d/pipewire-pulse << 'DSVC'
type = process
command = /usr/bin/pipewire-pulse
depends-on = pipewire
restart = true
DSVC

cat > /mnt/home/"$USERNAME"/.config/dinit.d/wireplumber << 'DSVC'
type = process
command = /usr/bin/wireplumber
depends-on = pipewire
restart = true
DSVC

chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.config/dinit.d

# --- STAGE 8: ZRAM ---
if [[ "$SWAP_CHOICE" =~ Zram|Both ]]; then
    artix-chroot /mnt pacman -S --noconfirm zramen zramen-dinit
    echo 'MAX_SIZE=2048' > /mnt/etc/default/zramen
fi

# --- STAGE 9: DESKTOP ENVIRONMENT ---
case "$DE_CHOICE" in
    Plasma)
        artix-chroot /mnt pacman -S --noconfirm plasma kde-applications sddm sddm-dinit \
            xdg-desktop-portal-kde plasma-pa
        ;;
    XFCE)
        artix-chroot /mnt pacman -S --noconfirm xfce4 xfce4-goodies \
            lightdm lightdm-dinit lightdm-gtk-greeter xdg-desktop-portal-gtk
        ;;
    LXQt)
        artix-chroot /mnt pacman -S --noconfirm lxqt sddm sddm-dinit
        ;;
    i3)
        artix-chroot /mnt pacman -S --noconfirm i3-wm dmenu \
            lightdm lightdm-dinit lightdm-gtk-greeter xterm
        ;;
    XMonad)
        artix-chroot /mnt pacman -S --noconfirm xmonad xmonad-contrib xmobar dmenu \
            lightdm lightdm-dinit lightdm-gtk-greeter xterm
        ;;
    WindowMaker)
        artix-chroot /mnt pacman -S --noconfirm windowmaker \
            lightdm lightdm-dinit lightdm-gtk-greeter xterm
        ;;
    Moksha)
        artix-chroot /mnt pacman -S --noconfirm moksha-artix \
            lightdm lightdm-dinit lightdm-gtk-greeter
        ;;
esac

# --- STAGE 10: DINIT SERVICES ---
mkdir -p /mnt/etc/dinit.d/boot.d
DM="lightdm"
[[ "$DE_CHOICE" =~ Plasma|LXQt ]] && DM="sddm"

# Service file names — not package names (dbus, not dbus-dinit; rtkit-daemon, not rtkit-dinit)
for svc in dbus NetworkManager elogind haveged rtkit-daemon "$DM"; do
    if [ -f "/mnt/etc/dinit.d/$svc" ]; then
        artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
    else
        echo "Warning: dinit service '$svc' not found, skipping."
    fi
done

[[ "$SWAP_CHOICE" =~ Zram|Both ]] && artix-chroot /mnt ln -sf /etc/dinit.d/zramen /etc/dinit.d/boot.d/

# --- STAGE 11: BOOTLOADER ---
artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# --- STAGE 12: UNMOUNT ---
umount -R /mnt

# --- DONE ---
if whiptail --title "$TITLE" --yesno "Installation complete! Reboot now?" 10 60; then
    reboot
else
    echo "Reboot cancelled. You may reboot manually later."
fi
