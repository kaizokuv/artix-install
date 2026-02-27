#!/bin/bash
set -e
set -o pipefail

# =========================
# SAFE RECOVERY
# =========================
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

# =========================
# ROOT CHECK
# =========================
if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

clear
TITLE="Artix Master Installer"

# =========================
# HELPERS
# =========================
get_password() {
    local prompt="$1"
    local p1 p2
    while true; do
        p1=$(whiptail --title "$TITLE" --passwordbox "$prompt" 10 60 3>&1 1>&2 2>&3) || exit 1
        p2=$(whiptail --title "$TITLE" --passwordbox "Confirm $prompt" 10 60 3>&1 1>&2 2>&3) || exit 1
        [ "$p1" = "$p2" ] && echo "$p1" && return
        whiptail --title "$TITLE" --msgbox "Passwords do not match." 8 40
    done
}

pick() {
    local title="$1" cmd="$2"
    local filter result
    while true; do
        filter=$(whiptail --title "$TITLE" --inputbox "$title — type to filter:" 10 60 "" 3>&1 1>&2 2>&3) || exit 1
        mapfile -t list < <(eval "$cmd" | grep -i "$filter" | head -50)
        [ ${#list[@]} -eq 0 ] && whiptail --title "$TITLE" --msgbox "No matches, try again." 8 40 && continue
        args=()
        for i in "${list[@]}"; do args+=("$i" "$i"); done
        result=$(whiptail --title "$TITLE" --menu "$title" 20 70 12 "${args[@]}" 3>&1 1>&2 2>&3) || continue
        echo "$result"
        return
    done
}

# =========================
# DISK
# =========================
mapfile -t disklist < <(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1; print $2}')
DISK=$(whiptail --title "$TITLE" --menu "Select Disk" 20 70 10 \
    "${disklist[@]}" 3>&1 1>&2 2>&3) || exit 1

# =========================
# FILESYSTEM
# =========================
FS=$(whiptail --title "$TITLE" --menu "Root Filesystem" 15 60 4 \
    "ext4"  "Ext4 (recommended)" \
    "btrfs" "Btrfs" \
    "xfs"   "XFS" \
    "f2fs"  "F2FS (flash-friendly)" \
    3>&1 1>&2 2>&3) || exit 1

# =========================
# SWAP
# =========================
SWAP=$(whiptail --title "$TITLE" --menu "Swap Configuration" 15 60 4 \
    "Zram"     "zram (compressed RAM swap)" \
    "Swapfile" "Swapfile on disk" \
    "Both"     "Zram + Swapfile" \
    "None"     "No swap" \
    3>&1 1>&2 2>&3) || exit 1

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_HALF_GB=$(( (RAM_KB / 1024 / 1024 + 1) / 2 ))
(( RAM_HALF_GB < 1  )) && RAM_HALF_GB=1
(( RAM_HALF_GB > 16 )) && RAM_HALF_GB=16

SWAP_SIZE_MB=4096
if [[ "$SWAP" =~ Swapfile|Both ]]; then
    SWAP_MENU_ARGS=()
    for SZ in 1 2 4 8 16; do
        if (( SZ == RAM_HALF_GB )); then
            SWAP_MENU_ARGS+=("$SZ" "${SZ} GB  <- recommended")
        else
            SWAP_MENU_ARGS+=("$SZ" "${SZ} GB")
        fi
    done
    SWAP_SIZE_GB=$(whiptail --title "$TITLE" --menu "Swapfile Size" 15 70 5 \
        "${SWAP_MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || exit 1
    SWAP_SIZE_MB=$(( SWAP_SIZE_GB * 1024 ))
fi

# =========================
# LOCALE / TIMEZONE / KEYBOARD
# =========================
LOCALE=$(pick "Locale" "grep UTF-8 /usr/share/i18n/SUPPORTED | awk '{print \$1}'")
TIMEZONE=$(pick "Timezone" "awk '/^[^#]/{print \$3}' /usr/share/zoneinfo/zone.tab | sort")

KB_LAYOUT=$(whiptail --title "$TITLE" --menu "Keyboard Layout" 30 74 22 \
    "us"        "English (US)" \
    "uk"        "English (UK)" \
    "us-intl"   "English (US International)" \
    "de"        "German" \
    "de-latin1" "German (Latin-1)" \
    "fr"        "French" \
    "fr-bepo"   "French (Bepo)" \
    "es"        "Spanish" \
    "it"        "Italian" \
    "pt"        "Portuguese" \
    "br"        "Portuguese (Brazil)" \
    "br-abnt2"  "Portuguese (Brazil ABNT2)" \
    "ru"        "Russian" \
    "pl"        "Polish" \
    "nl"        "Dutch" \
    "sv"        "Swedish" \
    "no"        "Norwegian" \
    "dk"        "Danish" \
    "fi"        "Finnish" \
    "hu"        "Hungarian" \
    "cz"        "Czech" \
    "cz-qwerty" "Czech (QWERTY)" \
    "sk"        "Slovak" \
    "ro"        "Romanian" \
    "bg"        "Bulgarian" \
    "gr"        "Greek" \
    "tr"        "Turkish" \
    "ua"        "Ukrainian" \
    "lt"        "Lithuanian" \
    "lv"        "Latvian" \
    "et"        "Estonian" \
    "il"        "Hebrew" \
    "ar"        "Arabic" \
    "jp106"     "Japanese (106 key)" \
    "kr"        "Korean" \
    "dvorak"    "Dvorak" \
    "colemak"   "Colemak" \
    3>&1 1>&2 2>&3) || exit 1

# =========================
# HOSTNAME / USER
# =========================
HOSTNAME=""
while [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9\-]+$ ]]; do
    HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname" 10 60 "artix" 3>&1 1>&2 2>&3) || exit 1
done

USERNAME=""
while [[ ! "$USERNAME" =~ ^[a-z][a-z0-9_\-]*$ ]]; do
    USERNAME=$(whiptail --title "$TITLE" --inputbox "Username" 10 60 "user" 3>&1 1>&2 2>&3) || exit 1
done

ROOTPW=$(get_password "Root Password")
USERPW=$(get_password "User Password")

# =========================
# DESKTOP
# =========================
INSTALL_TYPE=$(whiptail --title "$TITLE" --menu "Installation Type" 12 60 2 \
    "DE"  "Desktop Environment / Window Manager" \
    "CLI" "CLI only" \
    3>&1 1>&2 2>&3) || exit 1

DE_CHOICES="CLI"
if [ "$INSTALL_TYPE" = "DE" ]; then
    DE_CHOICES=$(whiptail --title "$TITLE" --checklist \
        "Select DE/WM (space to toggle, enter to confirm)" 24 70 10 \
        "Plasma"      "KDE Plasma"                      OFF \
        "XFCE"        "XFCE4"                            OFF \
        "LXQt"        "LXQt"                             OFF \
        "i3"          "i3wm"                             OFF \
        "XMonad"      "XMonad"                           OFF \
        "WindowMaker" "WindowMaker (from source)"        OFF \
        "Moksha"      "Moksha"                           OFF \
        "Cosmic"      "COSMIC [EXPERIMENTAL]"            OFF \
        3>&1 1>&2 2>&3) || exit 1
    DE_CHOICES=$(echo "$DE_CHOICES" | tr -d '"')
    if [ -z "$DE_CHOICES" ]; then
        whiptail --title "$TITLE" --msgbox "Nothing selected, defaulting to CLI." 8 50
        DE_CHOICES="CLI"
    fi
fi

# =========================
# KERNEL
# =========================
KERNEL_CHOICES=$(whiptail --title "$TITLE" --checklist \
    "Select kernel(s)" 15 60 3 \
    "linux"     "Standard"        ON  \
    "linux-lts" "LTS"             OFF \
    "linux-zen" "Zen (optimised)" OFF \
    3>&1 1>&2 2>&3) || exit 1
KERNEL_CHOICES=$(echo "$KERNEL_CHOICES" | tr -d '"')
[ -z "$KERNEL_CHOICES" ] && KERNEL_CHOICES="linux"
FIRST_KERNEL=$(echo "$KERNEL_CHOICES" | awk '{print $1}')

# =========================
# BOOTLOADER
# =========================
BOOT=$(whiptail --title "$TITLE" --menu "Bootloader" 12 60 3 \
    "grub"   "GRUB2 (most compatible)" \
    "limine" "Limine (fast, minimal)" \
    "refind" "rEFInd (graphical)" \
    3>&1 1>&2 2>&3) || exit 1

# =========================
# PARTITION
# =========================
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
case $FS in
    ext4)  mkfs.ext4  -F "$ROOT" ;;
    btrfs) mkfs.btrfs -f "$ROOT" ;;
    xfs)   mkfs.xfs   -f "$ROOT" ;;
    f2fs)  mkfs.f2fs  -f "$ROOT" ;;
esac

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# =========================
# SWAPFILE
# =========================
if [[ "$SWAP" =~ Swapfile|Both ]]; then
    if [[ "$FS" == "btrfs" ]]; then
        truncate -s 0 /mnt/swapfile
        chattr +C /mnt/swapfile
        fallocate -l "${SWAP_SIZE_GB}G" /mnt/swapfile
    else
        dd if=/dev/zero of=/mnt/swapfile bs=1M count="$SWAP_SIZE_MB" status=progress
    fi
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
fi

# =========================
# CPU / GPU DETECTION
# =========================
grep -qi intel /proc/cpuinfo && UCODE="intel-ucode" || true
grep -qi amd   /proc/cpuinfo && UCODE="amd-ucode"   || true

if lspci | grep -qi nvidia; then
    GPU="nvidia nvidia-utils"
elif lspci | grep -qiE "amd|radeon|advanced micro" || grep -qi amd /proc/cpuinfo; then
    GPU="mesa xf86-video-amdgpu vulkan-radeon"
else
    GPU="mesa"
fi

# =========================
# BASESTRAP
# =========================
basestrap /mnt \
    base "$FIRST_KERNEL" linux-firmware $UCODE \
    dinit elogind-dinit dbus-dinit \
    networkmanager networkmanager-dinit \
    doas rtkit haveged haveged-dinit \
    xorg-server xorg-xinit xdg-user-dirs \
    ntfs-3g dosfstools \
    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils \
    $GPU

fstabgen -U /mnt >> /mnt/etc/fstab

# Pacman optimizations
sed -i 's/^#Color/Color\nILoveCandy/' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /mnt/etc/pacman.conf

# Copy wifi connections from live ISO
if [ -d /etc/NetworkManager/system-connections ]; then
    mkdir -p /mnt/etc/NetworkManager/system-connections
    cp /etc/NetworkManager/system-connections/* \
        /mnt/etc/NetworkManager/system-connections/ 2>/dev/null || true
    chmod 600 /mnt/etc/NetworkManager/system-connections/* 2>/dev/null || true
fi

# Extra kernels
for K in $KERNEL_CHOICES; do
    [ "$K" = "$FIRST_KERNEL" ] && continue
    artix-chroot /mnt pacman -S --noconfirm "$K" "${K}-headers"
done

# =========================
# CHROOT CONFIG
# =========================
# Write passwords to files — avoids all encoding issues
printf '%s' "$ROOTPW" > /mnt/root/root_pw
printf '%s' "$USERPW"  > /mnt/root/user_pw
chmod 600 /mnt/root/root_pw /mnt/root/user_pw

cat > /mnt/root/setup.sh << EOF
#!/bin/bash
set -e

echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "KEYMAP=$KB_LAYOUT" > /etc/vconsole.conf
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << KBEOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KB_LAYOUT"
EndSection
KBEOF

echo "$HOSTNAME" > /etc/hostname

echo "root:\$(cat /root/root_pw)" | chpasswd
useradd -m -G wheel,audio,video,storage "$USERNAME"
echo "$USERNAME:\$(cat /root/user_pw)" | chpasswd
rm /root/root_pw /root/user_pw

echo "permit persist :wheel" > /etc/doas.conf
ln -sf /usr/bin/doas /usr/bin/sudo

su -s /bin/bash - "$USERNAME" -c "xdg-user-dirs-update"
EOF

chmod +x /mnt/root/setup.sh
artix-chroot /mnt /root/setup.sh
rm /mnt/root/setup.sh

# =========================
# PIPEWIRE AUTOSTART
# =========================
mkdir -p /mnt/usr/local/bin

cat > /mnt/usr/local/bin/start-pipewire << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pipewire &
sleep 0.5
pipewire-pulse &
wireplumber &
EOF
chmod +x /mnt/usr/local/bin/start-pipewire

USER_UID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f3)
USER_GID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f4)

# XDG autostart — works for Plasma X11, XFCE, LXQt
mkdir -p /mnt/home/"$USERNAME"/.config/autostart
cat > /mnt/home/"$USERNAME"/.config/autostart/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=/usr/local/bin/start-pipewire
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

# Plasma autostart-scripts — covers Plasma Wayland
mkdir -p /mnt/home/"$USERNAME"/.config/autostart-scripts
cat > /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pipewire &
sleep 0.5
pipewire-pulse &
wireplumber &
EOF
chmod +x /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh

# .xprofile — bare WMs via lightdm
cat > /mnt/home/"$USERNAME"/.xprofile << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pipewire &
sleep 0.5
pipewire-pulse &
wireplumber &
EOF

# Moksha
mkdir -p /mnt/home/"$USERNAME"/.e/e/applications/startup
cat > /mnt/home/"$USERNAME"/.e/e/applications/startup/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=/usr/local/bin/start-pipewire
EOF

chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"

# =========================
# ZRAM
# =========================
if [[ "$SWAP" =~ Zram|Both ]]; then
    ZRAM_MB=$(( RAM_KB / 1024 / 2 ))
    (( ZRAM_MB > 8192 )) && ZRAM_MB=8192

    cat > /mnt/usr/local/bin/zram-setup << EOF
#!/bin/bash
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || echo lzo > /sys/block/zram0/comp_algorithm
echo ${ZRAM_MB}M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
EOF
    chmod +x /mnt/usr/local/bin/zram-setup

    cat > /mnt/usr/local/bin/zram-teardown << 'EOF'
#!/bin/bash
swapoff /dev/zram0 2>/dev/null
echo 1 > /sys/block/zram0/reset
modprobe -r zram
EOF
    chmod +x /mnt/usr/local/bin/zram-teardown

    cat > /mnt/etc/dinit.d/zram << 'EOF'
type = scripted
command = /usr/local/bin/zram-setup
stop-command = /usr/local/bin/zram-teardown
EOF
fi

# =========================
# DESKTOP INSTALL
# =========================
if echo "$DE_CHOICES" | grep -qw "Cosmic"; then
    DM="greetd"
elif echo "$DE_CHOICES" | grep -qw "Plasma"; then
    DM="sddm"
elif [ "$DE_CHOICES" != "CLI" ]; then
    DM="lightdm"
else
    DM=""
fi

for DE in $DE_CHOICES; do
    case "$DE" in
        Plasma)
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
            artix-chroot /mnt pacman -S --noconfirm \
                base-devel wget \
                libx11 libxext libxmu libxpm libxt libxft fontconfig libpng pavucontrol
            artix-chroot /mnt bash -c "
                set -e
                cd /tmp
                WM_VER=\$(curl -s https://windowmaker.org/pub/source/release/ \
                    | grep -oP 'WindowMaker-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | sort -V | tail -1)
                [ -z \"\$WM_VER\" ] && echo 'ERROR: could not find WindowMaker tarball' && exit 1
                wget -q https://windowmaker.org/pub/source/release/\$WM_VER
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
            artix-chroot /mnt bash -c "
                grep -q '\[galaxy\]' /etc/pacman.conf || printf '\n[galaxy]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
                pacman -Sy --noconfirm
            "
            artix-chroot /mnt pacman -S --noconfirm \
                cosmic-session cosmic-greeter greetd greetd-dinit \
                xdg-desktop-portal-cosmic \
                cosmic-terminal cosmic-files cosmic-text-editor \
                cosmic-player cosmic-store cosmic-screenshot \
                cosmic-settings upower pavucontrol firefox
            for pam_file in system-login greetd; do
                PAM_PATH="/mnt/etc/pam.d/$pam_file"
                if [ -f "$PAM_PATH" ] && ! grep -q "pam_elogind" "$PAM_PATH"; then
                    echo "session required pam_elogind.so" >> "$PAM_PATH"
                fi
            done
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

if [ -n "$DM" ]; then
    if [[ "$DM" == "greetd" ]]; then
        : # installed in Cosmic case
    elif [[ "$DM" == "sddm" ]]; then
        artix-chroot /mnt pacman -S --noconfirm sddm sddm-dinit
    else
        artix-chroot /mnt pacman -S --noconfirm lightdm lightdm-dinit lightdm-gtk-greeter
    fi
fi

# =========================
# DINIT SERVICES
# =========================
mkdir -p /mnt/etc/dinit.d/boot.d

SVCS="dbus NetworkManager elogind haveged"
if [ -f /mnt/etc/dinit.d/rtkit-daemon ]; then
    SVCS="$SVCS rtkit-daemon"
elif [ -f /mnt/etc/dinit.d/rtkit ]; then
    SVCS="$SVCS rtkit"
fi
echo "$DE_CHOICES" | grep -qw "Cosmic" && SVCS="$SVCS upower"
[ -n "$DM" ] && SVCS="$SVCS $DM"

for svc in $SVCS; do
    if [ -f "/mnt/etc/dinit.d/$svc" ]; then
        artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
    else
        echo "Warning: dinit service '$svc' not found, skipping."
    fi
done

if [[ "$SWAP" =~ Zram|Both ]]; then
    [ -f "/mnt/etc/dinit.d/zram" ] && \
        artix-chroot /mnt ln -sf /etc/dinit.d/zram /etc/dinit.d/boot.d/
fi

# =========================
# BOOTLOADER
# =========================
case "$BOOT" in
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
                --disk $DISK --part 1 \
                --label 'Limine' \
                --loader '\\EFI\\limine\\BOOTX64.EFI'
        "
        KERNEL_IMG=$(ls /mnt/boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|/mnt/boot||')
        INITRD_IMG=$(ls /mnt/boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -1 | sed 's|/mnt/boot||')
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
        printf 'timeout: 5\n\n/Artix Linux\n    protocol: linux\n    kernel_path: boot():%s\n    cmdline: root=UUID=%s rw quiet\n    module_path: boot():%s\n' \
            "$KERNEL_IMG" "$ROOT_UUID" "$INITRD_IMG" > /mnt/boot/limine.conf
        ;;
    refind)
        artix-chroot /mnt pacman -S --noconfirm refind efibootmgr
        artix-chroot /mnt refind-install
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
        printf '"Boot with standard options"  "root=UUID=%s rw quiet"\n"Boot to terminal"            "root=UUID=%s rw init=/sbin/dinit"\n"Boot with minimal options"   "root=UUID=%s rw"\n' \
            "$ROOT_UUID" "$ROOT_UUID" "$ROOT_UUID" > /mnt/boot/refind_linux.conf
        ;;
esac

# =========================
# DONE
# =========================
umount -R /mnt
whiptail --title "$TITLE" --yesno "Install complete! Reboot now?" 10 50 && reboot || true
