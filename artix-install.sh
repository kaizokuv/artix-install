#!/bin/bash
# --- ERROR LOGGING & SAFETY ---
set -e
set -o pipefail

# This function runs if the script crashes
failure_handler() {
    echo "!!! ERROR occurred at line $1. Check /tmp/install_error.log for details."
    exit 1
}
trap 'failure_handler $LINENO' ERR
exec 2> >(tee /tmp/install_error.log) # Send all errors to a log file

# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

clear
TITLE="Artix Master Installer"

# --- HELPERS (Password/Lists) ---
get_confirmed_password() {
    local prompt="$1"
    local pw1 pw2
    while true; do
        pw1=$(whiptail --title "$TITLE" --passwordbox "$prompt" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && exit 1
        pw2=$(whiptail --title "$TITLE" --passwordbox "Confirm $prompt" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && exit 1
        if [ "$pw1" = "$pw2" ]; then echo "$pw1"; return; fi
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
            whiptail --title "$title" --msgbox "No matches for '$filter'." 8 50
            continue
        fi
        MENU_ARGS=()
        for item in "${MATCHES[@]}"; do MENU_ARGS+=("$item" "$item"); done
        result=$(whiptail --title "$title" --menu "Results" 20 70 12 "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && continue
        echo "$result"; return
    done
}

# --- STAGE 1: INPUTS ---
mapfile -t DISKLIST < <(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1; print $2}')
DISK=$(whiptail --title "$TITLE" --menu "Select Disk" 20 70 10 "${DISKLIST[@]}" 3>&1 1>&2 2>&3)
[ -z "$DISK" ] && exit 1

FS_CHOICE=$(whiptail --title "$TITLE" --menu "Filesystem" 15 60 4 "ext4" "Ext4" "btrfs" "Btrfs" "xfs" "XFS" "f2fs" "F2FS" 3>&1 1>&2 2>&3)
SWAP_CHOICE=$(whiptail --title "$TITLE" --menu "Swap" 15 60 4 "Zram" "Zram" "Swapfile" "Swapfile" "Both" "Both" "None" "None" 3>&1 1>&2 2>&3)

# ... (Previous logic for Swap size, Locale, Timezone, Keyboard, Hostname, Passwords) ...
# [Assuming those values are captured as before]

# --- STAGE 4: PACKAGE SELECTION (AUDIO & DRIVER FIXES) ---
if grep -qi "intel" /proc/cpuinfo; then UCODE="intel-ucode"; elif grep -qi "amd" /proc/cpuinfo; then UCODE="amd-ucode"; else UCODE=""; fi

if lspci | grep -qi "nvidia"; then
    GPU_PKGS="nvidia-dkms nvidia-utils"
elif lspci | grep -qiE "amd|radeon|advanced micro" || grep -qi "amd" /proc/cpuinfo; then
    GPU_PKGS="mesa xf86-video-amdgpu vulkan-radeon vulkan-mesa-layers"
else
    GPU_PKGS="mesa vulkan-intel"
fi

FIRST_KERNEL=$(echo "$KERNEL_CHOICES" | awk '{print $1}')
# Added Headers and GStreamer plugin for Plasma stability
BASE_PKGS="base $FIRST_KERNEL ${FIRST_KERNEL}-headers linux-firmware $UCODE dinit elogind-dinit dbus-dinit doas networkmanager networkmanager-dinit xorg-server xorg-xinit haveged haveged-dinit xdg-user-dirs"
AUDIO_PKGS="pipewire pipewire-alsa pipewire-pulse wireplumber gst-plugin-pipewire alsa-utils"

# --- STAGE 5-6: BASESTRAP & CONFIG ---
basestrap /mnt $BASE_PKGS $AUDIO_PKGS $GPU_PKGS
fstabgen -U /mnt >> /mnt/etc/fstab

# Copy error log for the user to see after reboot
cp /tmp/install_error.log /mnt/home/"$USERNAME"/install_log.txt || true

# --- STAGE 7: AUDIO (THE "NO MORE AUTO_NULL" FIX) ---
mkdir -p /mnt/usr/local/bin
cat > /mnt/usr/local/bin/start-pipewire << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
# Wait for session bus
for i in $(seq 1 15); do [ -d "$XDG_RUNTIME_DIR" ] && break; sleep 1; done

# Kill conflicts
pkill -u $(id -u) -x pipewire || true
pkill -u $(id -u) -x wireplumber || true
pkill -u $(id -u) -x pipewire-pulse || true
sleep 1

# Start sequence
/usr/bin/pipewire &
sleep 2
/usr/bin/pipewire-pulse &
/usr/bin/wireplumber &
EOF
chmod +x /mnt/usr/local/bin/start-pipewire

# Set up the autostart for Plasma/DEs
mkdir -p /mnt/home/"$USERNAME"/.config/autostart
cat > /mnt/home/"$USERNAME"/.config/autostart/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire Audio
Exec=/usr/local/bin/start-pipewire
Hidden=false
NoDisplay=true
EOF

# --- STAGE 11: BOOTLOADER (MICROCODE & CONFIG) ---
# [Insert the Stage 11 block provided in the previous message here]

# --- FINISH ---
umount -R /mnt
whiptail --title "$TITLE" --msgbox "Install complete! If audio is still weird, check ~/install_log.txt" 10 60
reboot
