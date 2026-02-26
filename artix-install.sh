#!/bin/bash
set -e
set -o pipefail

# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

clear
TITLE="Artix Master Installer"

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

# Swap size — only ask if swapfile is involved
# Detect half of RAM in GB as the recommended swap size
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_HALF_GB=$(( (RAM_KB / 1024 / 1024 + 1) / 2 ))
# Clamp to at least 1 GB and at most 16 GB
(( RAM_HALF_GB < 1  )) && RAM_HALF_GB=1
(( RAM_HALF_GB > 16 )) && RAM_HALF_GB=16

SWAP_SIZE_MB=2048
if [[ "$SWAP_CHOICE" =~ Swapfile|Both ]]; then
    SWAP_SIZE_GB=$(whiptail --title "$TITLE" --menu "Swapfile Size (recommended: ${RAM_HALF_GB} GB = half your RAM)" 15 70 5 \
        "1"  "1 GB" \
        "2"  "2 GB" \
        "4"  "4 GB" \
        "8"  "8 GB" \
        "16" "16 GB" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1
    # Default to recommended if user somehow gets an empty value
    SWAP_SIZE_GB="${SWAP_SIZE_GB:-$RAM_HALF_GB}"
    SWAP_SIZE_MB=$(( SWAP_SIZE_GB * 1024 ))
fi

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

# Multi-select DE/WM — whiptail checklist returns space-separated quoted selections
DE_CHOICES=$(whiptail --title "$TITLE" --checklist \
    "Select Desktop Environments / WMs (space to select, enter to confirm)" 22 70 10 \
    "Plasma"      "KDE Plasma"          OFF \
    "XFCE"        "XFCE4"               OFF \
    "LXQt"        "LXQt"                OFF \
    "i3"          "i3wm"                OFF \
    "XMonad"      "XMonad"              OFF \
    "WindowMaker" "WindowMaker (built from source)" OFF \
    "Moksha"      "Moksha"              OFF \
    "Cosmic"      "COSMIC (System76)"    OFF \
    3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1
# Strip quotes whiptail adds around each selection
DE_CHOICES=$(echo "$DE_CHOICES" | tr -d '"')
[ -z "$DE_CHOICES" ] && { whiptail --title "$TITLE" --msgbox "No environment selected. Exiting." 8 50; exit 1; }

BL_CHOICE=$(whiptail --title "$TITLE" --menu "Bootloader" 15 70 3 \
    "grub"   "GRUB2 (most compatible)" \
    "limine" "Limine (fast, minimal)" \
    "refind" "rEFInd (graphical picker)" 3>&1 1>&2 2>&3)
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
        fallocate -l "${SWAP_SIZE_GB}G" /mnt/swapfile
    else
        dd if=/dev/zero of=/mnt/swapfile bs=1M count="$SWAP_SIZE_MB" status=progress
    fi
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
fi

# --- STAGE 4: PACKAGE SELECTION ---

# CPU microcode — detect actual CPU instead of installing both
if grep -qi "intel" /proc/cpuinfo; then
    UCODE="intel-ucode"
elif grep -qi "amd" /proc/cpuinfo; then
    UCODE="amd-ucode"
else
    UCODE=""
fi

# GPU drivers — elif prevents AMD overwriting NVIDIA on hybrid systems
# xf86-video-intel is deprecated; modesetting (built into xorg) handles modern Intel
if lspci | grep -qi "nvidia"; then
    GPU_PKGS="nvidia nvidia-utils"
elif lspci | grep -qi "amd"; then
    GPU_PKGS="mesa xf86-video-amdgpu vulkan-mesa-layers"
else
    GPU_PKGS="mesa"
fi

# base-devel moved to WindowMaker case (only needed for compilation)
# wpa_supplicant removed — NM handles its own supplicant since 1.20
# vi, mtools, libnewt, efibootmgr removed — redundant or only needed on live ISO
# intel-ucode/amd-ucode replaced by auto-detected $UCODE above
BASE_PKGS="base linux linux-firmware $UCODE \
    dinit elogind-dinit dbus-dinit doas \
    networkmanager networkmanager-dinit \
    ntfs-3g dosfstools \
    xorg-server xorg-xinit \
    haveged haveged-dinit xdg-user-dirs \
    dbus rtkit"

# pavucontrol added conditionally per DE below — Plasma and COSMIC have native volume control
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils"

# --- STAGE 5: BASESTRAP ---
basestrap /mnt $BASE_PKGS $AUDIO_PKGS $GPU_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab

# --- STAGE 6: CHROOT CONFIGURATION ---
# Passwords base64-encoded so special chars ($, !, \) don't break the heredoc
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

su -s /bin/sh - "${CONFIGURE_USERNAME}" -c "xdg-user-dirs-update"
rm /root/install_env
CHROOT

chmod +x /mnt/root/configure.sh
artix-chroot /mnt /root/configure.sh
rm /mnt/root/configure.sh

# --- STAGE 7: AUDIO SETUP ---
# Multi-method pipewire startup to cover all DEs and WMs:
#
#  1. ~/.config/autostart/pipewire.desktop — XDG autostart, honoured by
#     XFCE, LXQt, Plasma (X11), and most freedesktop-compliant DEs
#  2. ~/.config/autostart-scripts/pipewire.sh — Plasma-specific, covers
#     Plasma Wayland where .xprofile is skipped
#  3. ~/.xprofile — sourced by lightdm before launching bare WMs
#     (i3, XMonad, WindowMaker). Not reliable for full DEs but essential here.
#  4. ~/.e/e/applications/startup/pipewire.desktop — Moksha/Enlightenment
#     specific autostart path, ignored by everything else

mkdir -p /mnt/home/"$USERNAME"

USER_UID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f3)
USER_GID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f4)

# --- METHOD 1: XDG autostart .desktop (XFCE, LXQt, Plasma X11) ---
mkdir -p /mnt/home/"$USERNAME"/.config/autostart
cat > /mnt/home/"$USERNAME"/.config/autostart/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire Audio
Exec=/usr/local/bin/start-pipewire
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

# --- METHOD 2: Plasma autostart-scripts (Plasma Wayland) ---
mkdir -p /mnt/home/"$USERNAME"/.config/autostart-scripts
cat > /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
EOF
chmod +x /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh

# --- METHOD 3: .xprofile (bare WMs: i3, XMonad, WindowMaker via lightdm) ---
cat > /mnt/home/"$USERNAME"/.xprofile << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
EOF

# --- METHOD 4: Moksha/Enlightenment autostart ---
mkdir -p /mnt/home/"$USERNAME"/.e/e/applications/startup
cat > /mnt/home/"$USERNAME"/.e/e/applications/startup/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire Audio
Exec=/usr/local/bin/start-pipewire
EOF

# Shared launcher script — all methods above call this so the logic lives in one place
cat > /mnt/usr/local/bin/start-pipewire << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
EOF
chmod +x /mnt/usr/local/bin/start-pipewire

# --- User dinit service files (TTY login fallback) ---
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

# Final recursive chown — covers everything including xdg dirs created as root
chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"

# --- STAGE 8: ZRAM ---
if [[ "$SWAP_CHOICE" =~ Zram|Both ]]; then
    artix-chroot /mnt pacman -S --noconfirm zramen zramen-dinit
    echo 'MAX_SIZE=2048' > /mnt/etc/default/zramen
fi

# --- STAGE 9: DESKTOP ENVIRONMENT ---
# Resolve display manager before installing DEs so we never install both.
# Priority: COSMIC (greetd) > Plasma (sddm) > everything else (lightdm)
# COSMIC uses its own greeter stack and conflicts with both sddm and lightdm.
if echo "$DE_CHOICES" | grep -qw "Cosmic"; then
    DM="greetd"
elif echo "$DE_CHOICES" | grep -qw "Plasma"; then
    DM="sddm"
else
    DM="lightdm"
fi

# Iterate over each selected DE — DE_CHOICES is space-separated
for DE in $DE_CHOICES; do
    case "$DE" in
        Plasma)
            # kde-applications is 200+ apps — install curated essentials instead
            artix-chroot /mnt pacman -S --noconfirm \
                plasma xdg-desktop-portal-kde plasma-pa \
                dolphin konsole kate ark okular gwenview kcalc
            ;;
        XFCE)
            artix-chroot /mnt pacman -S --noconfirm \
                xfce4 xfce4-goodies xdg-desktop-portal-gtk pavucontrol
            ;;
        LXQt)
            artix-chroot /mnt pacman -S --noconfirm lxqt pavucontrol
            ;;
        i3)
            artix-chroot /mnt pacman -S --noconfirm i3-wm dmenu xterm pavucontrol
            ;;
        XMonad)
            artix-chroot /mnt pacman -S --noconfirm \
                xmonad xmonad-contrib xmobar dmenu xterm pavucontrol
            ;;
        WindowMaker)
            # WindowMaker is not in the Artix repos — build from source
            # base-devel only installed here since no other DE needs a compiler
            artix-chroot /mnt pacman -S --noconfirm \
                base-devel wget \
                libx11 libxext libxmu libxpm libxt libxft fontconfig libpng pavucontrol
            artix-chroot /mnt bash -c "
                set -e
                cd /tmp
                # Fetch latest tarball filename from release page
                WM_VER=\$(curl -s https://windowmaker.org/pub/source/release/ \
                    | grep -oP 'WindowMaker-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
                    | sort -V | tail -1)
                [ -z \"\$WM_VER\" ] && echo 'ERROR: Could not detect WindowMaker version' && exit 1
                wget -q https://windowmaker.org/pub/source/release/\$WM_VER
                # Get the actual top-level directory name from the tarball
                WM_DIR=\$(tar -tzf \$WM_VER | head -1 | cut -d/ -f1)
                tar -xzf \$WM_VER
                cd \$WM_DIR
                ./configure --prefix=/usr --sysconfdir=/etc --enable-modelock
                make -j\$(nproc)
                make install
                cd /tmp && rm -rf \$WM_DIR \$WM_VER
            "
            ;;
        Moksha)
            artix-chroot /mnt pacman -S --noconfirm moksha-artix pavucontrol
            ;;
        Cosmic)
            # Enable galaxy repo — cosmic-* packages live there
            artix-chroot /mnt bash -c "
                grep -q '\[galaxy\]' /etc/pacman.conf || printf '
[galaxy]
Include = /etc/pacman.d/mirrorlist
' >> /etc/pacman.conf
                pacman -Sy --noconfirm
            "
            # seatd not used — elogind already handles seat management
            artix-chroot /mnt pacman -S --noconfirm \
                cosmic-session cosmic-greeter \
                greetd greetd-dinit \
                xdg-desktop-portal-cosmic \
                cosmic-terminal cosmic-files cosmic-text-editor \
                cosmic-player cosmic-store cosmic-screenshot \
                cosmic-settings pavucontrol
            # Write greetd config pointing to cosmic-greeter
            mkdir -p /mnt/etc/greetd
            cat > /mnt/etc/greetd/config.toml << 'EOF'
[terminal]
vt = 1

[default_session]
command = "cosmic-comp cosmic-greeter"
user = "cosmic-greeter"
EOF
            ;;
    esac
done

# Install the resolved display manager once, after all DEs are done
if [[ "$DM" == "greetd" ]]; then
    : # greetd already installed in the Cosmic case above
elif [[ "$DM" == "sddm" ]]; then
    artix-chroot /mnt pacman -S --noconfirm sddm sddm-dinit
else
    artix-chroot /mnt pacman -S --noconfirm lightdm lightdm-dinit lightdm-gtk-greeter
fi

# --- STAGE 10: DINIT SERVICES ---
mkdir -p /mnt/etc/dinit.d/boot.d

# Service file names — greetd for COSMIC, sddm for Plasma, lightdm for others
for svc in dbus NetworkManager elogind haveged rtkit-daemon "$DM"; do
    if [ -f "/mnt/etc/dinit.d/$svc" ]; then
        artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
    else
        echo "Warning: dinit service '$svc' not found, skipping."
    fi
done

[[ "$SWAP_CHOICE" =~ Zram|Both ]] && \
    artix-chroot /mnt ln -sf /etc/dinit.d/zramen /etc/dinit.d/boot.d/

# --- STAGE 11: BOOTLOADER ---
case "$BL_CHOICE" in
    grub)
        artix-chroot /mnt pacman -S --noconfirm grub efibootmgr
        artix-chroot /mnt grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot \
            --bootloader-id=Artix
        artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        ;;

    limine)
        artix-chroot /mnt pacman -S --noconfirm limine efibootmgr
        artix-chroot /mnt bash -c "
            mkdir -p /boot/EFI/limine
            cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
            efibootmgr --create \
                --disk ${DISK} \
                --part 1 \
                --label 'Limine' \
                --loader '\\EFI\\limine\\BOOTX64.EFI'
        "
        # Resolve values on the host before writing the config — no heredoc escaping issues
        # Strip /mnt/boot — EFI partition IS /boot so limine paths are relative to it
        # vmlinuz-* glob handles the kernel image regardless of name
        KERNEL_IMG=$(ls /mnt/boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|/mnt/boot||')
        INITRD_IMG=$(ls /mnt/boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -1 | sed 's|/mnt/boot||')
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
        printf 'timeout: 5

/Artix Linux
    protocol: linux
    kernel_path: boot():%s
    cmdline: root=UUID=%s rw quiet
    module_path: boot():%s
'             "$KERNEL_IMG" "$ROOT_UUID" "$INITRD_IMG" > /mnt/boot/limine.conf
        ;;

    refind)
        artix-chroot /mnt pacman -S --noconfirm refind efibootmgr
        artix-chroot /mnt refind-install
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
        printf '"Boot with standard options"  "root=UUID=%s rw quiet"
"Boot to terminal"            "root=UUID=%s rw init=/sbin/dinit"
"Boot with minimal options"   "root=UUID=%s rw"
'             "$ROOT_UUID" "$ROOT_UUID" "$ROOT_UUID" > /mnt/boot/refind_linux.conf
        ;;
esac

# --- STAGE 12: UNMOUNT ---
umount -R /mnt

# --- DONE ---
if whiptail --title "$TITLE" --yesno "Installation complete! Reboot now?" 10 60; then
    reboot
else
    echo "Reboot cancelled. You may reboot manually later."
fi
