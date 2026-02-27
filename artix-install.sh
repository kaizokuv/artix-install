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

pick_from_list() {
    local title="$1" prompt="$2" list_cmd="$3"
    local filter result
    while true; do
        filter=$(whiptail --title "$title" --inputbox "$prompt" 10 60 "" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && exit 1
        mapfile -t MATCHES < <(eval "$list_cmd" | grep -i "$filter" | head -50)
        if [ ${#MATCHES[@]} -eq 0 ]; then
            whiptail --title "$title" --msgbox "No matches for '$filter'. Try again." 8 50
            continue
        fi
        MENU_ARGS=()
        for item in "${MATCHES[@]}"; do
            MENU_ARGS+=("$item" "$item")
        done
        result=$(whiptail --title "$title" --menu "Results for '$filter'" 20 70 12 \
            "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && continue
        echo "$result"
        return
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
    "Zram"     "zram (via zramctl)" \
    "Swapfile" "Disk Swapfile" \
    "Both"     "Zram + Swapfile" \
    "None"     "No Swap" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1

# Detect half of RAM as recommended swap size
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_HALF_GB=$(( (RAM_KB / 1024 / 1024 + 1) / 2 ))
(( RAM_HALF_GB < 1  )) && RAM_HALF_GB=1
(( RAM_HALF_GB > 16 )) && RAM_HALF_GB=16

SWAP_SIZE_MB=2048
if [[ "$SWAP_CHOICE" =~ Swapfile|Both ]]; then
    SWAP_MENU_ARGS=()
    for SZ in 1 2 4 8 16; do
        if (( SZ == RAM_HALF_GB )); then
            SWAP_MENU_ARGS+=("$SZ" "${SZ} GB  <- recommended (half your RAM)")
        else
            SWAP_MENU_ARGS+=("$SZ" "${SZ} GB")
        fi
    done
    SWAP_SIZE_GB=$(whiptail --title "$TITLE" --menu "Swapfile Size" 15 70 5 \
        "${SWAP_MENU_ARGS[@]}" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1
    SWAP_SIZE_GB="${SWAP_SIZE_GB:-$RAM_HALF_GB}"
    SWAP_SIZE_MB=$(( SWAP_SIZE_GB * 1024 ))
fi

LOCALE=$(pick_from_list "$TITLE" \
    "Locale — type to filter (e.g. en_US, de_DE)" \
    "grep 'UTF-8' /usr/share/i18n/SUPPORTED | awk '{print \$1}'")
[ -z "$LOCALE" ] && exit 1

TIMEZONE=$(pick_from_list "$TITLE" \
    "Timezone — type to filter (e.g. Europe, America/New)" \
    "awk '/^[^#]/ {print \$3}' /usr/share/zoneinfo/zone.tab | sort")
[ -z "$TIMEZONE" ] && exit 1

KB_LAYOUT=$(whiptail --title "$TITLE" --menu "Keyboard Layout" 30 74 22 \
    "us"         "English (US)" \
    "uk"         "English (UK)" \
    "us-intl"    "English (US International)" \
    "de"         "German" \
    "de-latin1"  "German (Latin-1)" \
    "fr"         "French" \
    "fr-bepo"    "French (Bepo)" \
    "es"         "Spanish" \
    "it"         "Italian" \
    "pt"         "Portuguese" \
    "br"         "Portuguese (Brazil)" \
    "br-abnt2"   "Portuguese (Brazil ABNT2)" \
    "ru"         "Russian" \
    "pl"         "Polish" \
    "nl"         "Dutch" \
    "sv"         "Swedish" \
    "no"         "Norwegian" \
    "dk"         "Danish" \
    "fi"         "Finnish" \
    "hu"         "Hungarian" \
    "cz"         "Czech" \
    "cz-qwerty"  "Czech (QWERTY)" \
    "sk"         "Slovak" \
    "ro"         "Romanian" \
    "bg"         "Bulgarian" \
    "gr"         "Greek" \
    "tr"         "Turkish" \
    "ua"         "Ukrainian" \
    "lt"         "Lithuanian" \
    "lv"         "Latvian" \
    "et"         "Estonian" \
    "il"         "Hebrew" \
    "ar"         "Arabic" \
    "jp106"      "Japanese (106 key)" \
    "kr"         "Korean" \
    "dvorak"     "Dvorak" \
    "colemak"    "Colemak" \
    3>&1 1>&2 2>&3)
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

# Ask CLI or DE/WM first
INSTALL_TYPE=$(whiptail --title "$TITLE" --menu "Installation Type" 12 60 2 \
    "DE"  "Desktop Environment / Window Manager" \
    "CLI" "CLI only — no graphical interface" \
    3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1

if [ "$INSTALL_TYPE" = "CLI" ]; then
    DE_CHOICES="CLI"
else
    DE_CHOICES=$(whiptail --title "$TITLE" --checklist \
        "Select Desktop Environments / WMs (space to select, enter to confirm)" 24 70 12 \
        "Plasma"      "KDE Plasma"                      OFF \
        "XFCE"        "XFCE4"                            OFF \
        "LXQt"        "LXQt"                             OFF \
        "i3"          "i3wm"                             OFF \
        "XMonad"      "XMonad"                           OFF \
        "WindowMaker" "WindowMaker (built from source)"  OFF \
        "Moksha"      "Moksha"                           OFF \
        "Cosmic"      "COSMIC (System76) [EXPERIMENTAL]" OFF \
        3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1
    DE_CHOICES=$(echo "$DE_CHOICES" | tr -d '"')
    if [ -z "$DE_CHOICES" ]; then
        whiptail --title "$TITLE" --msgbox "No environment selected. Exiting." 8 50
        exit 1
    fi
fi

KERNEL_CHOICES=$(whiptail --title "$TITLE" --checklist \
    "Select kernel(s) to install" 15 70 3 \
    "linux"     "Standard — latest stable"  ON  \
    "linux-lts" "LTS — long term support"   OFF \
    "linux-zen" "Zen — desktop optimised"   OFF \
    3>&1 1>&2 2>&3)
[ $? -ne 0 ] && exit 1
KERNEL_CHOICES=$(echo "$KERNEL_CHOICES" | tr -d '"')
[ -z "$KERNEL_CHOICES" ] && KERNEL_CHOICES="linux"

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

# CPU microcode — detect actual CPU
if grep -qi "intel" /proc/cpuinfo; then
    UCODE="intel-ucode"
elif grep -qi "amd" /proc/cpuinfo; then
    UCODE="amd-ucode"
else
    UCODE=""
fi

# GPU detection — check lspci and /proc/cpuinfo for AMD APUs
if lspci | grep -qi "nvidia"; then
    GPU_PKGS="nvidia nvidia-utils"
elif lspci | grep -qiE "amd|radeon|advanced micro" || grep -qi "amd" /proc/cpuinfo; then
    GPU_PKGS="mesa xf86-video-amdgpu vulkan-mesa-layers"
else
    GPU_PKGS="mesa"
fi

FIRST_KERNEL=$(echo "$KERNEL_CHOICES" | awk '{print $1}')

BASE_PKGS="base $FIRST_KERNEL linux-firmware $UCODE \
    dinit elogind-dinit dbus-dinit doas \
    networkmanager networkmanager-dinit \
    ntfs-3g dosfstools \
    xorg-server xorg-xinit \
    haveged haveged-dinit xdg-user-dirs \
    dbus rtkit"

AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils"

# --- STAGE 5: BASESTRAP ---
basestrap /mnt $BASE_PKGS $AUDIO_PKGS $GPU_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab

# Copy NetworkManager connections from live ISO so wifi works on first boot
if [ -d /etc/NetworkManager/system-connections ]; then
    mkdir -p /mnt/etc/NetworkManager/system-connections
    cp /etc/NetworkManager/system-connections/* \
        /mnt/etc/NetworkManager/system-connections/ 2>/dev/null || true
    chmod 600 /mnt/etc/NetworkManager/system-connections/* 2>/dev/null || true
fi

# Install any additional kernels beyond the first
for K in $KERNEL_CHOICES; do
    [ "$K" = "$FIRST_KERNEL" ] && continue
    artix-chroot /mnt pacman -S --noconfirm "$K" "${K}-headers"
done

# --- STAGE 6: CHROOT CONFIGURATION ---
# Write passwords to tightly-permissioned files — avoids base64/heredoc encoding issues
printf '%s' "$ROOT_PW" > /mnt/root/root_pw
printf '%s' "$USER_PW" > /mnt/root/user_pw
chmod 600 /mnt/root/root_pw /mnt/root/user_pw

cat > /mnt/root/install_env << EOF
CONFIGURE_USERNAME=${USERNAME}
CONFIGURE_LOCALE=${LOCALE}
CONFIGURE_TIMEZONE=${TIMEZONE}
CONFIGURE_HOSTNAME=${HOSTNAME}
CONFIGURE_KB_LAYOUT=${KB_LAYOUT}
EOF
chmod 600 /mnt/root/install_env

cat > /mnt/root/configure.sh << 'CHROOT'
#!/bin/bash
set -e
source /root/install_env

# Read passwords directly from files — no encoding/decoding needed
ROOT_PW=$(cat /root/root_pw)
USER_PW=$(cat /root/user_pw)

echo "${CONFIGURE_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${CONFIGURE_LOCALE}" > /etc/locale.conf
ln -sf "/usr/share/zoneinfo/${CONFIGURE_TIMEZONE}" /etc/localtime
hwclock --systohc

echo "KEYMAP=${CONFIGURE_KB_LAYOUT}" > /etc/vconsole.conf
mkdir -p /etc/X11/xorg.conf.d
printf 'Section "InputClass"\n    Identifier "system-keyboard"\n    MatchIsKeyboard "on"\n    Option "XkbLayout" "%s"\nEndSection\n'     "${CONFIGURE_KB_LAYOUT}" > /etc/X11/xorg.conf.d/00-keyboard.conf

echo "${CONFIGURE_HOSTNAME}" > /etc/hostname

printf '%s:%s\n' "root" "$ROOT_PW" | chpasswd
useradd -m -G wheel,audio,video,storage "${CONFIGURE_USERNAME}"
printf '%s:%s\n' "${CONFIGURE_USERNAME}" "$USER_PW" | chpasswd

echo "permit persist :wheel" > /etc/doas.conf
ln -sf /usr/bin/doas /usr/bin/sudo

su -s /bin/sh - "${CONFIGURE_USERNAME}" -c "xdg-user-dirs-update"
rm /root/install_env /root/root_pw /root/user_pw
CHROOT

chmod +x /mnt/root/configure.sh
artix-chroot /mnt /root/configure.sh
rm /mnt/root/configure.sh

# --- STAGE 7: AUDIO SETUP ---
mkdir -p /mnt/home/"$USERNAME"

USER_UID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f3)
USER_GID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f4)

# Method 1: XDG autostart .desktop — XFCE, LXQt, Plasma X11
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

# Method 2: Plasma autostart-scripts — Plasma Wayland
mkdir -p /mnt/home/"$USERNAME"/.config/autostart-scripts
cat > /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for i in $(seq 1 10); do [ -d "$XDG_RUNTIME_DIR" ] && break; sleep 1; done
[ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; }
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
EOF
chmod +x /mnt/home/"$USERNAME"/.config/autostart-scripts/pipewire.sh

# Method 3: .xprofile — bare WMs (i3, XMonad, WindowMaker) via lightdm
cat > /mnt/home/"$USERNAME"/.xprofile << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for i in $(seq 1 10); do [ -d "$XDG_RUNTIME_DIR" ] && break; sleep 1; done
[ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; }
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
EOF

# Method 4: Moksha/Enlightenment autostart
mkdir -p /mnt/home/"$USERNAME"/.e/e/applications/startup
cat > /mnt/home/"$USERNAME"/.e/e/applications/startup/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire Audio
Exec=/usr/local/bin/start-pipewire
EOF

# Shared launcher used by all .desktop methods
cat > /mnt/usr/local/bin/start-pipewire << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for i in $(seq 1 10); do [ -d "$XDG_RUNTIME_DIR" ] && break; sleep 1; done
[ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; }
pgrep -x pipewire       >/dev/null || /usr/bin/pipewire &
sleep 1
pgrep -x wireplumber    >/dev/null || /usr/bin/wireplumber &
pgrep -x pipewire-pulse >/dev/null || /usr/bin/pipewire-pulse &
EOF
chmod +x /mnt/usr/local/bin/start-pipewire

# User dinit services — TTY login fallback
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

chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"

# --- STAGE 8: ZRAM ---
if [[ "$SWAP_CHOICE" =~ Zram|Both ]]; then
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

# --- STAGE 9: DESKTOP ENVIRONMENT ---
# Priority: COSMIC (greetd) > Plasma (sddm) > everything else (lightdm)
if echo "$DE_CHOICES" | grep -qw "Cosmic"; then
    DM="greetd"
elif echo "$DE_CHOICES" | grep -qw "Plasma"; then
    DM="sddm"
else
    DM="lightdm"
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
                    | grep -oP 'WindowMaker-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
                    | sort -V | tail -1)
                [ -z \"\$WM_VER\" ] && echo 'ERROR: Could not detect WindowMaker version' && exit 1
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
                cosmic-session cosmic-greeter \
                greetd greetd-dinit \
                xdg-desktop-portal-cosmic \
                cosmic-terminal cosmic-files cosmic-text-editor \
                cosmic-player cosmic-store cosmic-screenshot \
                cosmic-settings upower pavucontrol firefox
            # PAM elogind session registration — prevents cosmic-osd CPU spin
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

# Install display manager — skip for CLI
if [ "$DE_CHOICES" != "CLI" ]; then
    if [[ "$DM" == "greetd" ]]; then
        : # already installed in Cosmic case
    elif [[ "$DM" == "sddm" ]]; then
        artix-chroot /mnt pacman -S --noconfirm sddm sddm-dinit
    else
        artix-chroot /mnt pacman -S --noconfirm lightdm lightdm-dinit lightdm-gtk-greeter
    fi
fi

# --- STAGE 10: DINIT SERVICES ---
mkdir -p /mnt/etc/dinit.d/boot.d

EXTRA_SVCS=""
echo "$DE_CHOICES" | grep -qw "Cosmic" && EXTRA_SVCS="upower"

for svc in dbus NetworkManager elogind haveged rtkit-daemon $EXTRA_SVCS "$DM"; do
    if [ -f "/mnt/etc/dinit.d/$svc" ]; then
        artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
    else
        echo "Warning: dinit service '$svc' not found, skipping."
    fi
done

if [[ "$SWAP_CHOICE" =~ Zram|Both ]]; then
    if [ -f "/mnt/etc/dinit.d/zram" ]; then
        artix-chroot /mnt ln -sf /etc/dinit.d/zram /etc/dinit.d/boot.d/
    else
        echo "Warning: dinit service 'zram' not found, skipping."
    fi
fi

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

# --- STAGE 12: UNMOUNT ---
umount -R /mnt

if whiptail --title "$TITLE" --yesno "Installation complete! Reboot now?" 10 60; then
    reboot
else
    echo "Reboot cancelled. You may reboot manually later."
fi
