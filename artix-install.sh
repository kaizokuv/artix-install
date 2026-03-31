#!/bin/bash
set -e
set -o pipefail

# Detect firmware type
[ -d /sys/firmware/efi ] && UEFI=1 || UEFI=0

# Restore terminal and show log if install fails
 trap 'echo ""
       echo "INSTALL FAILED at line $LINENO"
       echo ""
       umount -R /mnt 2>/dev/null || true
       exit 1' ERR

# unmount/cleanup everything from a previous run so the script is re-runnable
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
# close any leftover LUKS mapping
cryptsetup close cryptroot 2>/dev/null || true

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
# TEST / FAST MODE
# =========================
# Pass --test as first arg to skip all prompts and do a fast CLI install
# Uses: first disk found, ext4, no swap, no encrypt, dinit, NM, linux kernel,
#       AMD cpu/gpu, GRUB, no DE, hostname=artix, user=user, pw=idk
#       AUR=yay, extra=alacritty feh picom rofi
TEST_MODE=0
if [ "${1:-}" = "--test" ]; then
    TEST_MODE=1
    DISK=$(lsblk -dpno NAME | grep -v loop | head -1)
    FS="ext4"
    SWAP="None"
    ENCRYPT=0; REAL_ROOT=""; LUKS_CMDLINE=""
    INIT="dinit"
    LOCALE="en_US.UTF-8"
    TIMEZONE="Europe/London"
    KB_LAYOUT="us"; VC_KEYMAP="us"
    HOSTNAME="artix"
    USERNAME="user"
    ROOTPW="idk"; USERPW="idk"
    INSTALL_TYPE="CLI"; DE_CHOICES="CLI"
    KERNEL_CHOICES="linux"; FIRST_KERNEL="linux"
    CPU_VENDOR="amd"; UCODE="amd-ucode"
    GPU_CHOICE="amd"; GPU="mesa vulkan-radeon"
    UEFI_ORIG="$UEFI"
    BOOT="grub"
    USE_XLIBRE=0; XORG_PKGS=""
    NET_CHOICE="NM"
    AUDIO_PKGS=""
    PRIV_ESC="doas"
    # partition layout
    [[ "$DISK" =~ (nvme|mmcblk) ]] && P="p" || P=""
    if [ "$UEFI" = "1" ]; then
        PART_DEVS=("${DISK}${P}1" "${DISK}${P}2")
        PART_SIZES=("1" "0")
        PART_TYPES=("EFI" "root")
        EFI="${DISK}${P}1"; ROOT="${DISK}${P}2"
    else
        PART_DEVS=("${DISK}${P}1")
        PART_SIZES=("0")
        PART_TYPES=("root")
        EFI=""; ROOT="${DISK}${P}1"
    fi
    DUALBOOT=0; SWAP_PART=""
    echo "==> TEST MODE: disk=$DISK boot=$BOOT uefi=$UEFI" --title "$TITLE" --msgbox "WARNING: This will erase the selected disk.\nMake sure you have backups.\n\nPress Enter to begin." 10 55
fi

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

# no pick() helper needed — using curated menus instead

# =========================
# =========================
# INIT SYSTEM
# =========================
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

if [ "$TEST_MODE" = "0" ]; then

# Step-based Q&A with back navigation
# Each step sets variables; pressing Cancel goes back one step
STEP=1
STEP_MAX=12

# defaults (overwritten by each step)
INIT="dinit"
DISK=""
FS="ext4"
SWAP="None"
SWAP_SIZE_GB=4
SWAP_SIZE_MB=4096
ENCRYPT=0; REAL_ROOT=""; LUKS_CMDLINE=""; LUKS_PW=""
LOCALE="en_US.UTF-8"
TIMEZONE="Europe/London"
KB_LAYOUT="us"
HOSTNAME="artix"
USERNAME="user"
ROOTPW=""; USERPW=""
INSTALL_TYPE="CLI"; DE_CHOICES="CLI"
KERNEL_CHOICES="linux"; FIRST_KERNEL="linux"
CPU_VENDOR="amd"; UCODE="amd-ucode"
GPU_CHOICE="vm"; GPU="mesa"
BOOT="grub"
USE_XLIBRE=0
NET_CHOICE="NM"
PRIV_ESC="doas"

RAM_HALF_GB=$(( (RAM_KB / 1024 / 1024 + 1) / 2 ))
(( RAM_HALF_GB < 1  )) && RAM_HALF_GB=1
(( RAM_HALF_GB > 16 )) && RAM_HALF_GB=16

while true; do
case "$STEP" in

1) # Init system
    _v=$(whiptail --title "$TITLE" --menu "Init System  [1/$STEP_MAX]" 12 60 2 \
        "dinit"  "dinit  — fast, dependency-based (recommended)" \
        "openrc" "openrc — traditional, widely supported" \
        3>&1 1>&2 2>&3) || exit 1
    INIT="$_v"; STEP=$(( STEP + 1 )) ;;

2) # Disk
    mapfile -t disklist < <(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1; print $2}')
    _v=$(whiptail --title "$TITLE" --menu "Select Disk  [2/$STEP_MAX]" 20 70 10 \
        "${disklist[@]}" 3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    DISK="$_v"; STEP=$(( STEP + 1 )) ;;

3) # Filesystem
    _v=$(whiptail --title "$TITLE" --menu "Root Filesystem  [3/$STEP_MAX]" 12 60 4 \
        "ext4"  "Ext4 (recommended)" \
        "btrfs" "Btrfs" \
        "xfs"   "XFS" \
        "f2fs"  "F2FS (flash-friendly)" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    FS="$_v"; STEP=$(( STEP + 1 )) ;;

4) # Swap
    _v=$(whiptail --title "$TITLE" --menu "Swap  [4/$STEP_MAX]" 12 60 4 \
        "Zram"     "zram (compressed RAM swap)" \
        "Swapfile" "Swapfile on disk" \
        "Both"     "Zram + Swapfile" \
        "None"     "No swap" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    SWAP="$_v"
    if [[ "$SWAP" =~ Swapfile|Both ]]; then
        SWAP_MENU_ARGS=()
        for SZ in 1 2 4 8 16; do
            (( SZ == RAM_HALF_GB )) \
                && SWAP_MENU_ARGS+=("$SZ" "${SZ}GB  <- recommended") \
                || SWAP_MENU_ARGS+=("$SZ" "${SZ}GB")
        done
        _v=$(whiptail --title "$TITLE" --menu "Swapfile Size  [4/$STEP_MAX]" 13 60 5 \
            "${SWAP_MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || continue
        SWAP_SIZE_GB="$_v"; SWAP_SIZE_MB=$(( SWAP_SIZE_GB * 1024 ))
    fi
    STEP=$(( STEP + 1 )) ;;

5) # Encryption
    if whiptail --title "$TITLE" --yesno \
        "Encryption  [5/$STEP_MAX]\n\nEnable full disk encryption (LUKS2)?\nYou will enter a passphrase on every boot." \
        10 60; then
        ENCRYPT=1
        LUKS_PW=$(get_password "Encryption Passphrase")
    else
        ENCRYPT=0; LUKS_PW=""
    fi
    STEP=$(( STEP + 1 )) ;;

6) # Locale + Timezone + Keyboard (one screen each, all in step 6 — back returns to step 5)
    _v=$(whiptail --title "$TITLE" --menu "Locale  [6/$STEP_MAX]" 20 60 12 \
        "en_US.UTF-8" "English (US)"            "en_GB.UTF-8" "English (UK)" \
        "en_AU.UTF-8" "English (Australia)"     "en_CA.UTF-8" "English (Canada)" \
        "de_DE.UTF-8" "German"                  "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish"                 "it_IT.UTF-8" "Italian" \
        "pt_BR.UTF-8" "Portuguese (Brazil)"     "pt_PT.UTF-8" "Portuguese (Portugal)" \
        "ru_RU.UTF-8" "Russian"                 "pl_PL.UTF-8" "Polish" \
        "nl_NL.UTF-8" "Dutch"                   "sv_SE.UTF-8" "Swedish" \
        "nb_NO.UTF-8" "Norwegian"               "da_DK.UTF-8" "Danish" \
        "fi_FI.UTF-8" "Finnish"                 "hu_HU.UTF-8" "Hungarian" \
        "cs_CZ.UTF-8" "Czech"                   "sk_SK.UTF-8" "Slovak" \
        "hr_HR.UTF-8" "Croatian"                "ro_RO.UTF-8" "Romanian" \
        "uk_UA.UTF-8" "Ukrainian"               "tr_TR.UTF-8" "Turkish" \
        "ja_JP.UTF-8" "Japanese"                "ko_KR.UTF-8" "Korean" \
        "zh_CN.UTF-8" "Chinese (Simplified)" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    LOCALE="$_v"
    _v=$(whiptail --title "$TITLE" --menu "Timezone  [6/$STEP_MAX]" 20 62 12 \
        "Europe/London"      "UK"                 "Europe/Dublin"     "Ireland" \
        "Europe/Paris"       "France/CET"         "Europe/Berlin"     "Germany" \
        "Europe/Amsterdam"   "Netherlands"        "Europe/Madrid"     "Spain" \
        "Europe/Rome"        "Italy"              "Europe/Warsaw"     "Poland" \
        "Europe/Stockholm"   "Sweden"             "Europe/Oslo"       "Norway" \
        "Europe/Copenhagen"  "Denmark"            "Europe/Helsinki"   "Finland" \
        "Europe/Budapest"    "Hungary"            "Europe/Prague"     "Czech Republic" \
        "Europe/Bratislava"  "Slovakia"           "Europe/Zagreb"     "Croatia" \
        "Europe/Bucharest"   "Romania"            "Europe/Kiev"       "Ukraine" \
        "Europe/Istanbul"    "Turkey"             "Europe/Moscow"     "Russia" \
        "America/New_York"   "US Eastern"         "America/Chicago"   "US Central" \
        "America/Denver"     "US Mountain"        "America/Los_Angeles" "US Pacific" \
        "America/Toronto"    "Canada Eastern"     "America/Sao_Paulo" "Brazil" \
        "Asia/Tokyo"         "Japan"              "Asia/Seoul"        "Korea" \
        "Asia/Shanghai"      "China"              "Australia/Sydney"  "Australia" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    TIMEZONE="$_v"
    _v=$(whiptail --title "$TITLE" --menu "Keyboard Layout  [6/$STEP_MAX]" 20 60 12 \
        "us" "English (US)"        "gb" "English (UK)" \
        "us-intl" "English (Intl)" "de" "German" \
        "de-latin1" "German (L1)"  "fr" "French" \
        "fr-bepo" "French (Bepo)"  "es" "Spanish" \
        "it" "Italian"             "pt" "Portuguese" \
        "br" "Portuguese (BR)"     "br-abnt2" "Portuguese (ABNT2)" \
        "ru" "Russian"             "pl" "Polish" \
        "nl" "Dutch"               "sv" "Swedish" \
        "no" "Norwegian"           "dk" "Danish" \
        "fi" "Finnish"             "hu" "Hungarian" \
        "cz" "Czech"               "cz-qwerty" "Czech (QWERTY)" \
        "sk" "Slovak"              "hr" "Croatian" \
        "ro" "Romanian"            "bg" "Bulgarian" \
        "gr" "Greek"               "tr" "Turkish" \
        "ua" "Ukrainian"           "dvorak" "Dvorak" \
        "colemak" "Colemak" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    KB_LAYOUT="$_v"
    STEP=$(( STEP + 1 )) ;;

7) # Hostname + username
    _v=$(whiptail --title "$TITLE" --inputbox "Hostname  [7/$STEP_MAX]" 10 60 "${HOSTNAME:-artix}" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    [[ "$_v" =~ ^[a-zA-Z0-9\-]+$ ]] && HOSTNAME="$_v" || \
        { whiptail --title "$TITLE" --msgbox "Invalid hostname. Use letters, numbers, hyphens only." 8 50; continue; }
    _v=$(whiptail --title "$TITLE" --inputbox "Username  [7/$STEP_MAX]" 10 60 "${USERNAME:-user}" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    [[ "$_v" =~ ^[a-z][a-z0-9_\-]*$ ]] && USERNAME="$_v" || \
        { whiptail --title "$TITLE" --msgbox "Invalid username. Use lowercase letters, numbers, _ or -." 8 55; continue; }
    ROOTPW=$(get_password "Root Password  [7/$STEP_MAX]")
    USERPW=$(get_password "User Password  [7/$STEP_MAX]")
    STEP=$(( STEP + 1 )) ;;

8) # Privilege escalation
    _v=$(whiptail --title "$TITLE" --menu "Privilege Escalation  [8/$STEP_MAX]" 12 60 2 \
        "doas"  "doas  — minimal, OpenBSD-style (recommended)" \
        "sudo"  "sudo  — standard, widely compatible" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    PRIV_ESC="$_v"; STEP=$(( STEP + 1 )) ;;

9) # Desktop
    _v=$(whiptail --title "$TITLE" --menu "Installation Type  [9/$STEP_MAX]" 10 60 2 \
        "DE"  "Desktop Environment / Window Manager" \
        "CLI" "CLI only" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    INSTALL_TYPE="$_v"
    DE_CHOICES="CLI"
    if [ "$INSTALL_TYPE" = "DE" ]; then
        DE_CHOICES=$(whiptail --title "$TITLE" --checklist \
            "Select DE/WM  [9/$STEP_MAX]  (space=toggle)" 20 70 11 \
            "Plasma"   "KDE Plasma"              OFF \
            "XFCE"     "XFCE4"                   OFF \
            "LXQt"     "LXQt"                    OFF \
            "i3"       "i3wm"                    OFF \
            "XMonad"   "XMonad"                  OFF \
            "Openbox"  "Openbox"                 OFF \
            "Fluxbox"  "Fluxbox"                 OFF \
            "IceWM"    "IceWM"                   OFF \
            "Hyprland" "Hyprland (Wayland)"      OFF \
            "Moksha"   "Moksha"                  OFF \
            "Cosmic"   "COSMIC [EXPERIMENTAL]"   OFF \
            3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
        DE_CHOICES=$(echo "$DE_CHOICES" | tr -d '"')
        [ -z "$DE_CHOICES" ] && DE_CHOICES="CLI"
    fi
    STEP=$(( STEP + 1 )) ;;

10) # Kernel + CPU + GPU
    KERNEL_CHOICES=$(whiptail --title "$TITLE" --checklist \
        "Kernel  [10/$STEP_MAX]" 14 70 5 \
        "linux"         "Standard"                                    ON  \
        "linux-lts"     "LTS — long term support"                     OFF \
        "linux-zen"     "Zen — desktop optimised"                     OFF \
        "linux-lqx"     "Liquorix — low latency"                      OFF \
        "linux-cachyos" "CachyOS — BORE scheduler (adds CachyOS repo)" OFF \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    KERNEL_CHOICES=$(echo "$KERNEL_CHOICES" | tr -d '"')
    [ -z "$KERNEL_CHOICES" ] && KERNEL_CHOICES="linux"
    FIRST_KERNEL=$(echo "$KERNEL_CHOICES" | awk '{print $1}')
    _v=$(whiptail --title "$TITLE" --menu "CPU Vendor  [10/$STEP_MAX]" 10 50 3 \
        "intel" "Intel" "amd" "AMD" "other" "Other / VM" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    CPU_VENDOR="$_v"
    case "$CPU_VENDOR" in
        intel) UCODE="intel-ucode" ;; amd) UCODE="amd-ucode" ;; *) UCODE="" ;;
    esac
    _v=$(whiptail --title "$TITLE" --menu "GPU  [10/$STEP_MAX]" 13 60 5 \
        "intel"  "Intel iGPU" \
        "amd"    "AMD" \
        "nvidia" "Nvidia" \
        "hybrid" "Hybrid Intel+Nvidia" \
        "vm"     "VM / none (mesa only)" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    GPU_CHOICE="$_v"
    case "$GPU_CHOICE" in
        intel)  GPU="mesa vulkan-intel" ;;
        amd)    GPU="mesa vulkan-radeon" ;;
        nvidia) GPU="mesa nvidia nvidia-utils" ;;
        hybrid) GPU="mesa vulkan-intel nvidia nvidia-utils" ;;
        vm)     GPU="mesa" ;;
    esac
    STEP=$(( STEP + 1 )) ;;

11) # Bootloader
    if [ "$UEFI" = "1" ]; then
        _v=$(whiptail --title "$TITLE" --menu "Bootloader  [11/$STEP_MAX]" 12 65 3 \
            "grub"   "GRUB2 — most compatible, required for dual-boot" \
            "limine" "Limine — fast, minimal" \
            "refind" "rEFInd — graphical" \
            3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
        BOOT="$_v"
    else
        BOOT="grub"
    fi
    STEP=$(( STEP + 1 )) ;;

12) # Xorg + Network
    USE_XLIBRE=0
    if [ "$DE_CHOICES" != "CLI" ] && \
       ! echo "$DE_CHOICES" | grep -qw "Cosmic" && \
       ! echo "$DE_CHOICES" | grep -qw "Hyprland"; then
        if whiptail --title "$TITLE" --yesno \
            "XLibre or Xorg?  [12/$STEP_MAX]\n\nXLibre is Artix's actively maintained Xorg fork.\nTearFree by default, from galaxy-gremlins repo.\n\nYes = XLibre   No = standard Xorg" \
            12 60; then
            USE_XLIBRE=1
        fi
    fi
    _v=$(whiptail --title "$TITLE" --menu "Network Stack  [12/$STEP_MAX]" 13 65 3 \
        "dhcpcd" "dhcpcd  — ethernet only, ~2MB" \
        "iwd"    "iwd     — wifi + ethernet, ~5MB" \
        "NM"     "NetworkManager — full featured, ~30MB" \
        3>&1 1>&2 2>&3) || { STEP=$(( STEP - 1 )); continue; }
    NET_CHOICE="$_v"
    STEP=$(( STEP + 1 )) ;;

esac
[ "$STEP" -gt "$STEP_MAX" ] && break
[ "$STEP" -lt 1 ] && STEP=1
done

fi  # end TEST_MODE=0 Q&A

# partition manager
if [ "$TEST_MODE" = "0" ]; then
DISK_SIZE=$(lsblk -bdno SIZE "$DISK" 2>/dev/null || echo 0)
DISK_SIZE_GB=$(( DISK_SIZE / 1024 / 1024 / 1024 ))
EFI=""; ROOT=""; DUALBOOT=0
[[ "$DISK" =~ (nvme|mmcblk) ]] && P="p" || P=""

PART_MODE=$(whiptail --title "$TITLE" --menu \
    "Partitioning — $DISK (${DISK_SIZE_GB}GB)" 13 65 3 \
    "auto"     "Auto — wipe disk, use entire drive (recommended)" \
    "manual"   "Manual — open cfdisk to partition yourself" \
    "dualboot" "Dual-boot — keep existing partitions, pick root" \
    3>&1 1>&2 2>&3) || exit 1

case "$PART_MODE" in
    auto)
        if [ "$UEFI" = "1" ]; then
            PART_DEVS=( "${DISK}${P}1" "${DISK}${P}2" )
            PART_SIZES=( "1" "0" )
            PART_TYPES=( "EFI" "root" )
            EFI="${DISK}${P}1"; ROOT="${DISK}${P}2"
        else
            PART_DEVS=( "${DISK}${P}1" )
            PART_SIZES=( "0" )
            PART_TYPES=( "root" )
            ROOT="${DISK}${P}1"
        fi
        ;;
    manual)
        whiptail --title "$TITLE" --msgbox \
            "cfdisk will open now.\n\nCreate your partitions and write the table.\nAfter exiting you will select which partitions to use." \
            10 60
        cfdisk "$DISK"
        udevadm settle
        # Let user pick root (and EFI if UEFI)
        mapfile -t _parts < <(lsblk -pno NAME,SIZE,FSTYPE "$DISK" | grep -v "^$DISK " | \
            awk '{print $1; printf "%s %s\n", $2, ($3=="" ? "unformatted" : $3)}')
        if [ "$UEFI" = "1" ]; then
            EFI=$(whiptail --title "$TITLE" --menu "Select EFI partition" \
                16 60 8 "${_parts[@]}" 3>&1 1>&2 2>&3) || exit 1
        fi
        ROOT=$(whiptail --title "$TITLE" --menu "Select root partition (will be formatted as $FS)" \
            16 60 8 "${_parts[@]}" 3>&1 1>&2 2>&3) || exit 1
        PART_DEVS=(); PART_SIZES=(); PART_TYPES=()
        [ "$UEFI" = "1" ] && { PART_DEVS+=("$EFI"); PART_SIZES+=("0"); PART_TYPES+=("EFI"); }
        PART_DEVS+=("$ROOT"); PART_SIZES+=("0"); PART_TYPES+=("root")
        ;;
    dualboot)
        DUALBOOT=1
        mapfile -t allparts < <(lsblk -pno NAME,SIZE,FSTYPE,PARTTYPE | \
            grep -v '^/dev/[a-z]*[[:space:]]' | \
            awk '{print $1; printf "%s %s %s\n", $2, ($3=="" ? "unformatted" : $3), ($4=="" ? "" : "[EFI]")}')
        EFI=$(whiptail --title "$TITLE" --menu \
            "Select your existing EFI partition (do NOT format it)" \
            18 72 10 "${allparts[@]}" 3>&1 1>&2 2>&3) || exit 1
        mapfile -t rootparts < <(lsblk -pno NAME,SIZE,FSTYPE "$DISK" | \
            grep -v "^$DISK " | \
            awk '{print $1; printf "%s %s\n", $2, ($3=="" ? "unformatted" : $3)}')
        ROOT=$(whiptail --title "$TITLE" --menu \
            "Select partition for Artix root (will be formatted as $FS)" \
            18 72 10 "${rootparts[@]}" 3>&1 1>&2 2>&3) || exit 1
        PART_DEVS=("$ROOT"); PART_SIZES=("0"); PART_TYPES=("root")
        ;;
esac
fi  # end TEST_MODE=0 partition manager

if [ "$DUALBOOT" = "0" ] && [ "${PART_MODE:-auto}" != "manual" ]; then
    # Fresh install — wipe and write new partition table via sfdisk
    wipefs -af "$DISK"
    {
        [ "$UEFI" = "1" ] && echo "label: gpt" || echo "label: dos"
        echo "label-id: $(cat /proc/sys/kernel/random/uuid)"
        for i in "${!PART_DEVS[@]}"; do
            SZ="${PART_SIZES[$i]}"
            TYPE="${PART_TYPES[$i]}"
            if [ "$UEFI" = "1" ]; then
                case "$TYPE" in
                    EFI)  TYPECODE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ;;
                    swap) TYPECODE="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" ;;
                    *)    TYPECODE="0FC63DAF-8483-4772-8E79-3D69D8477DE4" ;;
                esac
                [ "$SZ" = "0" ] \
                    && echo "size=+, type=$TYPECODE" \
                    || echo "size=+${SZ}G, type=$TYPECODE"
            else
                case "$TYPE" in
                    swap) TYPECODE="82" ;;
                    *)    TYPECODE="83" ;;
                esac
                BOOTFLAG=""; [ "$TYPE" = "root" ] && BOOTFLAG=", bootable"
                [ "$SZ" = "0" ] \
                    && echo "size=+, type=$TYPECODE$BOOTFLAG" \
                    || echo "size=+${SZ}G, type=$TYPECODE$BOOTFLAG"
            fi
        done
    } | sfdisk "$DISK"
    udevadm settle
    [ "$UEFI" = "1" ] && mkfs.fat -F32 "$EFI"
    # Format swap partition now — activate after mount so fstabgen sees it
    SWAP_PART=""
    for i in "${!PART_TYPES[@]}"; do
        if [ "${PART_TYPES[$i]}" = "swap" ]; then
            SWAP_PART="${PART_DEVS[$i]}"
            mkswap "$SWAP_PART"
        fi
    done
else
    # Dual-boot or manual — partition table already written, just settle
    udevadm settle
    SWAP_PART=""
fi

if [ "$ENCRYPT" = "1" ]; then
    command -v cryptsetup &>/dev/null || pacman -Sy --noconfirm cryptsetup
    echo -n "$LUKS_PW" | cryptsetup luksFormat --type luks2 "$ROOT" -
    echo -n "$LUKS_PW" | cryptsetup open "$ROOT" cryptroot -
    REAL_ROOT="$ROOT"
    ROOT="/dev/mapper/cryptroot"
fi

case $FS in
    ext4)  mkfs.ext4  -F "$ROOT" ;;
    btrfs) mkfs.btrfs -f "$ROOT" ;;
    xfs)   mkfs.xfs   -f "$ROOT" ;;
    f2fs)  mkfs.f2fs  -f "$ROOT" ;;
esac

mount "$ROOT" /mnt
mkdir -p /mnt/boot
[ "$UEFI" = "1" ] && mount "$EFI" /mnt/boot

# Activate swap partition now so fstabgen picks it up
[ -n "${SWAP_PART:-}" ] && swapon "$SWAP_PART"

# section headers during install
gauge() {
    echo ""
    echo "==> ${2}"
    echo ""
}

# swapfile
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
    swapon /mnt/swapfile  # activate so fstabgen picks it up
fi

# icewm doesnt need mesa/llvm so skip gpu entirely to save ~200mb
BARE_WM_ONLY=1
for _de in Plasma XFCE LXQt Moksha Cosmic Hyprland i3 XMonad Openbox Fluxbox; do
    echo "$DE_CHOICES" | grep -qw "$_de" && BARE_WM_ONLY=0 && break
done
[ "$DE_CHOICES" = "CLI" ] && BARE_WM_ONLY=0
[ "$BARE_WM_ONLY" = "1" ] && GPU=""

# XORG_PKGS set from USE_XLIBRE chosen upfront
XORG_PKGS=""
if [ "$DE_CHOICES" != "CLI" ] && ! echo "$DE_CHOICES" | grep -qw "Cosmic" && ! echo "$DE_CHOICES" | grep -qw "Hyprland"; then
    if [ "$USE_XLIBRE" = "1" ]; then
        XORG_PKGS="xlibre-xserver xlibre-xserver-common xorg-xinit"
    else
        XORG_PKGS="xorg-server xorg-xinit xf86-input-libinput"
    fi
fi

# Only install audio stack for DEs that actually use it
AUDIO_PKGS=""
AUDIO_DES="Plasma XFCE LXQt Moksha Cosmic Hyprland"
for _de in $AUDIO_DES; do
    if echo "$DE_CHOICES" | grep -qw "$_de"; then
        AUDIO_PKGS="pipewire pipewire-pulse pipewire-alsa wireplumber"
        break
    fi
done

# =========================
gauge 15 "Configuring repositories..."
# XLIBRE REPO (if needed)
# =========================
if [ "$USE_XLIBRE" = "1" ]; then
    grep -q '\[galaxy-gremlins\]' /etc/pacman.conf || \
        printf '\n[galaxy-gremlins]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    pacman -Sy --noconfirm
fi

# =========================
# LIQUORIX REPO (if needed)
# =========================
if echo "$KERNEL_CHOICES" | grep -qw "linux-lqx"; then
    pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys 9AE4078033F8024D
    pacman-key --lsign-key 9AE4078033F8024D
    grep -q 'liquorix.net' /etc/pacman.conf || \
        printf '\n[liquorix]\nServer = https://liquorix.net/archlinux/$repo/$arch\n' >> /etc/pacman.conf
    pacman -Sy
fi

# cachyos repo — only needed for linux-cachyos kernel
if echo "$KERNEL_CHOICES" | grep -qw "linux-cachyos"; then
    _cachy_ok=0
    set +e

    # Temporarily set global SigLevel = Never so pacman can install the keyring
    # package before we have CachyOS keys trusted. Per-repo SigLevel is unreliable
    # across pacman versions — global override is the only thing that always works.
    _orig_siglevel=$(grep '^SigLevel' /etc/pacman.conf | head -1)
    [ -z "$_orig_siglevel" ] && _orig_siglevel="SigLevel = Required DatabaseOptional"
    sed -i "s/^SigLevel.*/${_orig_siglevel}/" /etc/pacman.conf  # ensure it exists first
    sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf

    # Add the repo (with a plain Server line, no per-repo SigLevel needed now)
    grep -q '\[cachyos\]' /etc/pacman.conf || printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n' >> /etc/pacman.conf

    pacman -Sy --noconfirm 2>/dev/null
    pacman -S --noconfirm cachyos-keyring cachyos-mirrorlist

    # Restore global SigLevel and populate the keyring properly
    sed -i "s/^SigLevel.*/${_orig_siglevel}/" /etc/pacman.conf
    pacman-key --populate cachyos

    # Switch repo to use mirrorlist include now that mirrorlist is installed
    sed -i '/^\[cachyos\]/{n; s|^Server = .*|Include = /etc/pacman.d/cachyos-mirrorlist|}' /etc/pacman.conf

    pacman -Sy --noconfirm && pacman -Si linux-cachyos &>/dev/null && _cachy_ok=1

    set -e
    if [ "$_cachy_ok" = "0" ]; then
        # Restore original SigLevel in case it got left as Never
        sed -i "s/^SigLevel.*/${_orig_siglevel}/" /etc/pacman.conf
        sed -i '/^\[cachyos\]/,/^$/d' /etc/pacman.conf
        whiptail --title "$TITLE" --msgbox \
            "CachyOS repo setup failed.\nFalling back to linux kernel." 10 60
        KERNEL_CHOICES=$(echo "$KERNEL_CHOICES" | sed 's/linux-cachyos/linux/g' | tr -s ' ')
        FIRST_KERNEL=$(echo "$KERNEL_CHOICES" | awk '{print $1}')
    fi
fi

gauge 20 "Installing base system (this takes a while)..."
# =========================
# BASESTRAP
# =========================
basestrap /mnt \
    base "$FIRST_KERNEL" linux-firmware $UCODE \
    $([ "$INIT" = "dinit" ] && echo "dinit elogind-dinit dbus-dinit" || echo "openrc elogind-openrc dbus-openrc") \
    $([ "$NET_CHOICE" = "NM" ] && { [ "$INIT" = "dinit" ] && echo "networkmanager networkmanager-dinit" || echo "networkmanager networkmanager-openrc"; }) \
    $([ "$PRIV_ESC" = "sudo" ] && echo "sudo" || echo "doas") $([ -n "$AUDIO_PKGS" ] && echo rtkit) \
    ttf-dejavu ttf-liberation noto-fonts \
    $XORG_PKGS \
    $AUDIO_PKGS \
    $GPU

gauge 35 "Writing fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab

# Persist XLibre repo and finish input driver install
if [ "$USE_XLIBRE" = "1" ]; then
    grep -q '\[galaxy-gremlins\]' /mnt/etc/pacman.conf || \
        printf '\n[galaxy-gremlins]\nInclude = /etc/pacman.d/mirrorlist\n' >> /mnt/etc/pacman.conf
    # xlibre-input-libinput conflicts with xf86-input-libinput — install after server
    artix-chroot /mnt pacman -Sy --noconfirm
    artix-chroot /mnt pacman -S --noconfirm xlibre-input-libinput
fi

# Encryption setup inside installed system
if [ "$ENCRYPT" = "1" ]; then
    # Ensure cryptsetup is in the installed system
    artix-chroot /mnt pacman -S --noconfirm cryptsetup
    # crypttab — maps cryptroot on boot
    LUKS_UUID=$(blkid -s UUID -o value "$REAL_ROOT")
    echo "cryptroot UUID=$LUKS_UUID none luks" >> /mnt/etc/crypttab

    # Add encrypt hook to mkinitcpio
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf
    artix-chroot /mnt mkinitcpio -P

    # Store LUKS UUID for bootloader cmdline
    LUKS_CMDLINE="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot"
fi

# pacman tweaks
sed -i 's/^#Color/Color\nILoveCandy/' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /mnt/etc/pacman.conf
# Block legacy xf86-video DDX drivers — modesetting handles everything
# Prevents DE metapackages from pulling them in as optional deps
grep -q 'xf86-video-amdgpu' /mnt/etc/pacman.conf || \
    sed -i '/^\[options\]/a IgnorePkg = xf86-video-amdgpu xf86-video-intel xf86-video-nouveau xf86-video-fbdev xf86-video-vesa' \
    /mnt/etc/pacman.conf

# liquorix repo in the installed system
if echo "$KERNEL_CHOICES" | grep -qw "linux-lqx"; then
    artix-chroot /mnt pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys 9AE4078033F8024D
    artix-chroot /mnt pacman-key --lsign-key 9AE4078033F8024D
    grep -q 'liquorix.net' /mnt/etc/pacman.conf || \
        printf '\n[liquorix]\nServer = https://liquorix.net/archlinux/$repo/$arch\n' >> /mnt/etc/pacman.conf
    artix-chroot /mnt pacman -Sy --noconfirm
fi

# cachyos repo in the installed system
if echo "$KERNEL_CHOICES" | grep -qw "linux-cachyos"; then
    _orig_siglevel=$(grep '^SigLevel' /mnt/etc/pacman.conf | head -1)
    [ -z "$_orig_siglevel" ] && _orig_siglevel="SigLevel = Required DatabaseOptional"
    sed -i 's/^SigLevel.*/SigLevel = Never/' /mnt/etc/pacman.conf
    grep -q '\[cachyos\]' /mnt/etc/pacman.conf || \
        printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n' >> /mnt/etc/pacman.conf
    artix-chroot /mnt pacman -Sy --noconfirm
    artix-chroot /mnt pacman -S --noconfirm cachyos-keyring cachyos-mirrorlist
    sed -i "s/^SigLevel.*/${_orig_siglevel}/" /mnt/etc/pacman.conf
    artix-chroot /mnt pacman-key --populate cachyos
    sed -i '/^\[cachyos\]/{n; s|^Server = .*|Include = /etc/pacman.d/cachyos-mirrorlist|}' /mnt/etc/pacman.conf
    artix-chroot /mnt pacman -Sy --noconfirm
fi

# Install headers for lqx/cachyos if selected as first kernel
if [ "$FIRST_KERNEL" = "linux-lqx" ]; then
    artix-chroot /mnt pacman -S --noconfirm linux-lqx-headers
elif [ "$FIRST_KERNEL" = "linux-cachyos" ]; then
    : # cachyos bundles headers
fi
# copy NM wifi profiles when NM is selected
if [ "$NET_CHOICE" = "NM" ] && [ -d /etc/NetworkManager/system-connections ]; then
    mkdir -p /mnt/etc/NetworkManager/system-connections
    cp /etc/NetworkManager/system-connections/* \
        /mnt/etc/NetworkManager/system-connections/ 2>/dev/null || true
    chmod 600 /mnt/etc/NetworkManager/system-connections/* 2>/dev/null || true
fi

# Extra kernels
for K in $KERNEL_CHOICES; do
    [ "$K" = "$FIRST_KERNEL" ] && continue
    if [ "$K" = "linux-cachyos" ]; then
        artix-chroot /mnt pacman -S --noconfirm linux-cachyos
    elif [ "$K" = "linux-lqx" ]; then
        artix-chroot /mnt pacman -S --noconfirm linux-lqx linux-lqx-headers
    else
        artix-chroot /mnt pacman -S --noconfirm "$K" "${K}-headers"
    fi
done

# locale and timezone
gauge 40 "Setting locale..."
artix-chroot /mnt bash -c "echo '$LOCALE UTF-8' >> /etc/locale.gen && locale-gen"
artix-chroot /mnt bash -c "echo 'LANG=$LOCALE' > /etc/locale.conf"
gauge 45 "Setting timezone..."
artix-chroot /mnt bash -c "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc"

# keyboard layout
# Map X11 layout name to vconsole keymap (they differ for some layouts)
case "$KB_LAYOUT" in
    us-intl)   VC_KEYMAP="us" ;;
    cz-qwerty) VC_KEYMAP="cz-qwerty" ;;
    fr-bepo)   VC_KEYMAP="fr-bepo" ;;
    br-abnt2)  VC_KEYMAP="br-abnt2" ;;
    de-latin1) VC_KEYMAP="de-latin1" ;;
    jp106)     VC_KEYMAP="jp106" ;;
    *)         VC_KEYMAP="$KB_LAYOUT" ;;
esac
cat > /mnt/etc/vconsole.conf << EOF
KEYMAP=$VC_KEYMAP
FONT=default
EOF
mkdir -p /mnt/etc/X11/xorg.conf.d
cat > /mnt/etc/X11/xorg.conf.d/00-keyboard.conf << KBEOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KB_LAYOUT"
EndSection
KBEOF

# hostname
gauge 50 "Configuring hostname..."
echo "$HOSTNAME" > /mnt/etc/hostname
printf "127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost\n" "$HOSTNAME" > /mnt/etc/hosts

# Passwords — read directly from files inside chroot, no encoding needed
# Passwords — pass directly as env vars, no files, no subshells
ROOTPW_B64=$(printf '%s' "$ROOTPW" | base64)
USERPW_B64=$(printf '%s' "$USERPW" | base64)
artix-chroot /mnt bash -c "echo root:\$(echo $ROOTPW_B64 | base64 -d) | chpasswd"
gauge 55 "Creating user account..."
artix-chroot /mnt bash -c "useradd -m -G wheel,audio,video,storage,input '$USERNAME'"
artix-chroot /mnt bash -c "echo $USERNAME:\$(echo $USERPW_B64 | base64 -d) | chpasswd"
USER_UID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f3)
USER_GID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f4)

# privilege escalation config
if [ "$PRIV_ESC" = "doas" ]; then
    cat > /mnt/etc/doas.conf << 'EOF'
permit persist :wheel
permit nopass :wheel cmd pacman
EOF
    chmod 0400 /mnt/etc/doas.conf
    # symlink sudo -> doas so tools that hardcode sudo still work
    [ ! -e /mnt/usr/bin/sudo ] && artix-chroot /mnt ln -s /usr/bin/doas /usr/bin/sudo || true
else
    # sudo — configure sudoers
    if [ -f /mnt/etc/sudoers ]; then
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers
        sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /mnt/etc/sudoers
    else
        mkdir -p /mnt/etc/sudoers.d
        echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
        chmod 0440 /mnt/etc/sudoers.d/wheel
    fi
fi

# xdg dirs — create standard dirs directly, avoids chroot session issues
for d in Desktop Documents Downloads Music Pictures Public Templates Videos; do
    mkdir -p "/mnt/home/$USERNAME/$d"
done
chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"

# =========================
# PIPEWIRE AUTOSTART (only for DEs that use audio)
# =========================
AUDIO_DES_CHECK="Plasma XFCE LXQt Moksha Cosmic Hyprland"
NEED_AUDIO=0
for _de in $AUDIO_DES_CHECK; do
    echo "$DE_CHOICES" | grep -qw "$_de" && NEED_AUDIO=1 && break
done

mkdir -p /mnt/usr/local/bin
if [ "$NEED_AUDIO" = "1" ]; then

cat > /mnt/usr/local/bin/start-pipewire << 'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Kill any stale instances first so we start clean
pkill -u "$USER" -fx /usr/bin/pipewire-pulse 2>/dev/null || true
pkill -u "$USER" -fx /usr/bin/wireplumber     2>/dev/null || true
pkill -u "$USER" -fx /usr/bin/pipewire        2>/dev/null || true
sleep 0.5

# Start pipewire and wait for its socket — not a fixed sleep
/usr/bin/pipewire &
i=0
while [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ] && [ $i -lt 10 ]; do
    sleep 1; i=$((i+1))
done

# Now safe to start wireplumber and pipewire-pulse
/usr/bin/wireplumber &
i=0
while [ "$(pgrep -fx /usr/bin/wireplumber)" = "" ] && [ $i -lt 10 ]; do
    sleep 1; i=$((i+1))
done
/usr/bin/pipewire-pulse &
EOF
chmod +x /mnt/usr/local/bin/start-pipewire

# XDG autostart — works for Plasma X11, XFCE, LXQt
mkdir -p /mnt/home/"$USERNAME"/.config/autostart
cat > /mnt/home/"$USERNAME"/.config/autostart/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=/usr/local/bin/start-pipewire
X-KDE-autostart-phase=1
EOF

# Note: autostart-scripts/ intentionally omitted — KDE auto-converts scripts
# in that directory into broken .desktop files pointing to wrong paths

if echo "$DE_CHOICES" | grep -qw "Moksha"; then
    mkdir -p /mnt/home/"$USERNAME"/.e/e/applications/startup
    cat > /mnt/home/"$USERNAME"/.e/e/applications/startup/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=/usr/local/bin/start-pipewire
EOF
fi
fi # end NEED_AUDIO

chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"

# bare WMs autologin on tty1 and startx
BARE_WMS="i3 XMonad Openbox Fluxbox IceWM"
for _wm in $BARE_WMS; do
    if echo "$DE_CHOICES" | grep -qw "$_wm"; then
        # startx on login if on tty1
        cat >> /mnt/home/"$USERNAME"/.bash_profile << 'EOF'
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx
EOF
        chown "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.bash_profile
        # autologin
        if [ "$INIT" = "dinit" ]; then
            cat > /mnt/etc/dinit.d/agetty-tty1 << EOF
type = process
command = /sbin/agetty --autologin $USERNAME --noclear tty1 38400 linux
restart = true
depends-on = elogind
EOF
        else
            # OpenRC: per-tty conf.d override
            mkdir -p /mnt/etc/conf.d
            cat > /mnt/etc/conf.d/agetty.tty1 << EOF
agetty_options="--autologin $USERNAME --noclear"
EOF
            # OpenRC PAM: ensure pam_elogind registers the session
            # and nullok lets empty-password autologin through cleanly
            for pam_file in login system-auth; do
                PAM_PATH="/mnt/etc/pam.d/$pam_file"
                [ -f "$PAM_PATH" ] || continue
                # nullok on pam_unix auth so autologin isn't rejected
                sed -i 's/pam_unix.so$/pam_unix.so nullok/' "$PAM_PATH" 2>/dev/null || true
                # pam_elogind session registration
                grep -q 'pam_elogind.so' "$PAM_PATH" || \
                    echo 'session optional pam_elogind.so' >> "$PAM_PATH"
            done
        fi
        break
    fi
done

gauge 60 "Configuring swap..."
# zram swap
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

    if [ "$INIT" = "dinit" ]; then
        cat > /mnt/etc/dinit.d/zram << 'EOF'
type = scripted
command = /usr/local/bin/zram-setup
stop-command = /usr/local/bin/zram-teardown
EOF
    else
        # OpenRC service
        cat > /mnt/etc/init.d/zram << 'EOF'
#!/sbin/openrc-run
description="zram swap"
command="/usr/local/bin/zram-setup"
stop() { /usr/local/bin/zram-teardown; }
EOF
        chmod +x /mnt/etc/init.d/zram
    fi
fi

gauge 65 "Installing desktop environment..."
# install whatever DE/WM the user picked
if echo "$DE_CHOICES" | grep -qw "Cosmic"; then
    DM="greetd"
elif echo "$DE_CHOICES" | grep -qw "Hyprland"; then
    DM="greetd"
elif echo "$DE_CHOICES" | grep -qw "Plasma"; then
    DM="sddm"
elif echo "$DE_CHOICES" | grep -qwE "XFCE|LXQt|Moksha"; then
    DM="lightdm"
else
    DM=""
fi

for DE in $DE_CHOICES; do
    case "$DE" in
        Plasma)
            artix-chroot /mnt pacman -S --noconfirm \
                plasma-desktop kwin plasma-pa plasma-nm \
                powerdevil kscreen kde-gtk-config \
                breeze breeze-gtk knotifications \
                polkit-kde-agent xdg-desktop-portal-kde \
                dolphin konsole spectacle ark gwenview \
                plasma-systemmonitor ksystemstats bluedevil
            ;;
        XFCE)
            artix-chroot /mnt pacman -S --noconfirm \
                xfce4 xfce4-goodies xdg-desktop-portal-gtk \
                pavucontrol thunar-archive-plugin
            ;;
        LXQt)
            artix-chroot /mnt pacman -S --noconfirm lxqt
            ;;
        i3)
            artix-chroot /mnt pacman -S --noconfirm i3-wm dmenu xterm
            ;;
        XMonad)
            artix-chroot /mnt pacman -S --noconfirm artix-archlinux-support
            if ! grep -q '\[extra\]' /mnt/etc/pacman.conf; then
                printf '\n# Arch repos\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> /mnt/etc/pacman.conf
                artix-chroot /mnt pacman-key --populate archlinux
            fi
            artix-chroot /mnt pacman -Sy --noconfirm
            artix-chroot /mnt pacman -S --noconfirm xmonad xmonad-contrib xterm dmenu git
            artix-chroot /mnt bash -c "
                mkdir -p /home/$USERNAME/.config
                git clone https://github.com/feribsd/xmonad-dotfiles.git /tmp/xmonad-dotfiles
                cp -r /tmp/xmonad-dotfiles/. /home/$USERNAME/.config/
                rm -rf /tmp/xmonad-dotfiles
                chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/
            "
            ;;
        Openbox)
            artix-chroot /mnt pacman -S --noconfirm openbox xterm dmenu
            ;;
        Fluxbox)
            artix-chroot /mnt pacman -S --noconfirm fluxbox xterm dmenu
            ;;
        IceWM)
            artix-chroot /mnt pacman -S --noconfirm icewm xterm
            mkdir -p /mnt/home/"$USERNAME"/.config/icewm
            ;;
        Hyprland)
            artix-chroot /mnt pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland
            mkdir -p /mnt/home/"$USERNAME"/.config/hypr
            cat >> /mnt/home/"$USERNAME"/.config/hypr/hyprland.conf << 'HYPREOF'
exec-once = /usr/local/bin/start-pipewire
HYPREOF
            chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.config/hypr
            mkdir -p /mnt/usr/share/wayland-sessions
            cat > /mnt/usr/share/wayland-sessions/hyprland.desktop << 'EOF'
[Desktop Entry]
Name=Hyprland
Comment=A dynamic tiling Wayland compositor
Exec=Hyprland
Type=Application
EOF
            ;;
        Moksha)
            artix-chroot /mnt pacman -S --noconfirm moksha-artix
            ;;
        Cosmic)
            artix-chroot /mnt bash -c "
                grep -q '\[galaxy\]' /etc/pacman.conf || printf '\n[galaxy]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
                pacman -Sy --noconfirm
            "
            artix-chroot /mnt pacman -S --noconfirm \
                cosmic-session cosmic-comp cosmic-greeter \
                $([ "$INIT" = "dinit" ] && echo "greetd greetd-dinit" || echo "greetd greetd-openrc") \
                xdg-desktop-portal-cosmic cosmic-terminal \
                cosmic-files cosmic-text-editor cosmic-settings \
                cosmic-screenshot cosmic-store upower pavucontrol
            # Create cosmic-greeter system user if missing
            artix-chroot /mnt id cosmic-greeter >/dev/null 2>&1 || \
                artix-chroot /mnt useradd -r -M -G video,audio,input cosmic-greeter
            # PAM elogind session registration
            for pam_file in system-login greetd; do
                PAM_PATH="/mnt/etc/pam.d/$pam_file"
                if [ -f "$PAM_PATH" ] && ! grep -q "pam_elogind.so" "$PAM_PATH"; then
                    echo "session required pam_elogind.so" >> "$PAM_PATH"
                fi
            done

            # Stub out systemd dbus interfaces that cosmic-osd/cosmic-settings poll for
            # Without these stubs they spin at 99% CPU waiting for a response that never comes
            mkdir -p /mnt/usr/share/dbus-1/services
            for svc in org.freedesktop.systemd1 org.freedesktop.login1; do
                cat > "/mnt/usr/share/dbus-1/services/${svc}.service" << DBUSEOF
[D-BUS Service]
Name=${svc}
Exec=/bin/false
DBUSEOF
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

# write .xinitrc for bare WMs — done after loop so all WMs are installed
BARE_WMS_SELECTED=""
for _wm in i3 XMonad Openbox Fluxbox IceWM; do
    echo "$DE_CHOICES" | grep -qw "$_wm" && BARE_WMS_SELECTED="$BARE_WMS_SELECTED $_wm"
done
BARE_WMS_SELECTED="${BARE_WMS_SELECTED# }"

if [ -n "$BARE_WMS_SELECTED" ]; then
    wm_exec() {
        case "$1" in
            i3)      echo "exec i3" ;;
            XMonad)  echo "exec xmonad" ;;
            Openbox) echo "exec openbox-session" ;;
            Fluxbox) echo "exec startfluxbox" ;;
            IceWM)   echo "exec icewm-session" ;;
        esac
    }
    WM_COUNT=$(echo "$BARE_WMS_SELECTED" | wc -w)
    {
        cat << 'XINITRC_HEADER'
#!/bin/sh
rm -f /tmp/.X*-lock /tmp/.X11-unix/X*
xset s off; xset -dpms; xset s noblank
xset fp+ /usr/share/fonts/TTF 2>/dev/null
xset fp+ /usr/share/fonts/dejavu 2>/dev/null
xset fp rehash 2>/dev/null
XINITRC_HEADER
        if [ "$WM_COUNT" -eq 1 ]; then
            wm_exec "$BARE_WMS_SELECTED"
        else
            echo "echo 'Select window manager:'"
            IDX=1
            for _wm in $BARE_WMS_SELECTED; do
                echo "echo '  $IDX) $_wm'"
                IDX=$(( IDX + 1 ))
            done
            echo "printf 'Choice: '"
            echo "read -r _choice"
            IDX=1
            for _wm in $BARE_WMS_SELECTED; do
                echo "[ "\$_choice" = "$IDX" ] && $(wm_exec $_wm)"
                IDX=$(( IDX + 1 ))
            done
            wm_exec "$(echo "$BARE_WMS_SELECTED" | awk '{print $1}')"
        fi
    } > /mnt/home/"$USERNAME"/.xinitrc
    chmod +x /mnt/home/"$USERNAME"/.xinitrc
    chown "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.xinitrc
fi

if [ -n "$DM" ]; then
    if [[ "$DM" == "greetd" ]]; then
        if ! echo "$DE_CHOICES" | grep -qw "Cosmic"; then
            # greetd for Hyprland
            artix-chroot /mnt pacman -S --noconfirm $([ "$INIT" = "dinit" ] && echo "greetd greetd-dinit" || echo "greetd greetd-openrc")
            mkdir -p /mnt/etc/greetd
            cat > /mnt/etc/greetd/config.toml << EOF
[terminal]
vt = 1

[default_session]
command = "Hyprland"
user = "$USERNAME"
EOF
        fi
        : # COSMIC installs its own greetd in the Cosmic case block
    elif [[ "$DM" == "sddm" ]]; then
        artix-chroot /mnt pacman -S --noconfirm $([ "$INIT" = "dinit" ] && echo "sddm sddm-dinit" || echo "sddm sddm-openrc")
    elif [[ "$DM" == "lightdm" ]]; then
        artix-chroot /mnt pacman -S --noconfirm $([ "$INIT" = "dinit" ] && echo "lightdm lightdm-dinit lightdm-gtk-greeter" || echo "lightdm lightdm-openrc lightdm-gtk-greeter")
    fi
fi


gauge 85 "Enabling services..."
# enable services

# CPU governor
cat > /mnt/etc/cpupower.conf << 'EOF'
governor='schedutil'
EOF

# Install chosen network stack + migrate NM wifi profiles if needed
case "$NET_CHOICE" in
    dhcpcd)
        if [ "$INIT" = "dinit" ]; then
            artix-chroot /mnt pacman -S --noconfirm dhcpcd dhcpcd-dinit
        else
            artix-chroot /mnt pacman -S --noconfirm dhcpcd dhcpcd-openrc
        fi
        NET_SVC="dhcpcd"
        ;;
    iwd)
        if [ "$INIT" = "dinit" ]; then
            artix-chroot /mnt pacman -S --noconfirm iwd iwd-dinit
        else
            artix-chroot /mnt pacman -S --noconfirm iwd iwd-openrc
        fi
        NET_SVC="iwd"
        if [ -d /etc/NetworkManager/system-connections ]; then
            mkdir -p /mnt/var/lib/iwd
            for nmconf in /etc/NetworkManager/system-connections/*.nmconnection; do
                [ -f "$nmconf" ] || continue
                SSID=$(awk -F= '/^ssid=/{print $2}' "$nmconf")
                PSK=$(awk -F= '/^psk=/{print $2}' "$nmconf")
                [ -z "$SSID" ] && continue
                IWDFILE="/mnt/var/lib/iwd/${SSID}.psk"
                [ -n "$PSK" ] && printf '[Security]\nPassphrase=%s\n' "$PSK" > "$IWDFILE" \
                              || printf '[Security]\n' > "$IWDFILE"
                chmod 600 "$IWDFILE"
                echo "Migrated wifi: $SSID"
            done
        fi
        ;;
    NM)
        NET_SVC="NetworkManager"
        ;;
esac

if [ "$INIT" = "dinit" ]; then
    artix-chroot /mnt pacman -S --noconfirm cpupower cpupower-dinit
    mkdir -p /mnt/etc/dinit.d/boot.d
    SVCS="dbus $NET_SVC elogind cpupower"
    [ -f /mnt/etc/dinit.d/rtkit-daemon ] && SVCS="$SVCS rtkit-daemon" \
        || { [ -f /mnt/etc/dinit.d/rtkit ] && SVCS="$SVCS rtkit"; }
    echo "$DE_CHOICES" | grep -qw "Cosmic" && SVCS="$SVCS upower turnstiled"
    [ -n "$DM" ] && SVCS="$SVCS $DM"
    for svc in $SVCS; do
        if [ -f "/mnt/etc/dinit.d/$svc" ]; then
            artix-chroot /mnt ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
        else
            echo "Warning: dinit service '$svc' not found, skipping."
        fi
    done
    [[ "$SWAP" =~ Zram|Both ]] && [ -f /mnt/etc/dinit.d/zram ] && \
        artix-chroot /mnt ln -sf /etc/dinit.d/zram /etc/dinit.d/boot.d/ || true
    for tty in 2 3 4 5 6; do
        rm -f /mnt/etc/dinit.d/boot.d/getty@tty${tty} 2>/dev/null || true
        artix-chroot /mnt dinitctl disable getty@tty${tty} 2>/dev/null || true
    done
else
    # OpenRC
    artix-chroot /mnt pacman -S --noconfirm cpupower cpupower-openrc
    SVCS="dbus $NET_SVC elogind cpupower"
    [ -f /mnt/etc/init.d/rtkit ] && SVCS="$SVCS rtkit"
    echo "$DE_CHOICES" | grep -qw "Cosmic" && SVCS="$SVCS upower"
    [ -n "$DM" ] && SVCS="$SVCS $DM"
    for svc in $SVCS; do
        artix-chroot /mnt rc-update add "$svc" default 2>/dev/null \
            || echo "Warning: openrc service '$svc' not found, skipping."
    done
    [[ "$SWAP" =~ Zram|Both ]] && artix-chroot /mnt rc-update add zram boot 2>/dev/null || true
    for tty in 2 3 4 5 6; do
        artix-chroot /mnt rc-update del agetty.tty${tty} 2>/dev/null || true
    done
fi

gauge 90 "Installing bootloader..."
# =========================
# BOOTLOADER
# =========================
case "$BOOT" in
    grub)
        artix-chroot /mnt pacman -S --noconfirm grub
        [ "$UEFI" = "1" ] && artix-chroot /mnt pacman -S --noconfirm efibootmgr
        if [ "$DUALBOOT" = "1" ]; then
            # os-prober detects other OSes (Windows etc) for GRUB menu
            artix-chroot /mnt pacman -S --noconfirm os-prober
            sed -i 's/^#GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /mnt/etc/default/grub
            grep -q 'GRUB_DISABLE_OS_PROBER' /mnt/etc/default/grub || \
                echo 'GRUB_DISABLE_OS_PROBER=false' >> /mnt/etc/default/grub
            # Mount other partitions so os-prober can find them
            mount --bind /dev  /mnt/dev
            mount --bind /proc /mnt/proc
            mount --bind /sys  /mnt/sys
        fi
        if [ "$UEFI" = "1" ]; then
            artix-chroot /mnt grub-install \
                --target=x86_64-efi \
                --efi-directory=/boot \
                --bootloader-id=Artix \
                --recheck
        else
            artix-chroot /mnt grub-install --target=i386-pc --recheck "$DISK"
        fi
        if [ "$ENCRYPT" = "1" ]; then
            GRUB_LUKS="cryptdevice=UUID=$(blkid -s UUID -o value "$REAL_ROOT"):cryptroot root=/dev/mapper/cryptroot"
            sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_LUKS\"|" /mnt/etc/default/grub
            sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /mnt/etc/default/grub
        fi
        artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        # Unmount bind mounts used by os-prober
        [ "$DUALBOOT" = "1" ] && { umount /mnt/sys /mnt/proc /mnt/dev 2>/dev/null || true; }
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
        if [ "$ENCRYPT" = "1" ]; then
            PART_UUID=$(blkid -s UUID -o value "$REAL_ROOT")
            LIMINE_CMDLINE="cryptdevice=UUID=$PART_UUID:cryptroot root=/dev/mapper/cryptroot rw quiet"
        else
            ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
            LIMINE_CMDLINE="root=UUID=$ROOT_UUID rw quiet"
        fi
        cat > /mnt/boot/limine.conf << EOF
timeout: 5

/Artix Linux
    protocol: linux
    path: boot():/vmlinuz-$FIRST_KERNEL
    cmdline: $LIMINE_CMDLINE
    module_path: boot():/initramfs-$FIRST_KERNEL.img
EOF
        ;;
    refind)
        artix-chroot /mnt pacman -S --noconfirm refind efibootmgr
        artix-chroot /mnt refind-install
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
        if [ "$ENCRYPT" = "1" ]; then
            printf '"Boot with standard options"  "%s root=/dev/mapper/cryptroot rw quiet"\n' \
                "$LUKS_CMDLINE" > /mnt/boot/refind_linux.conf
        else
            printf '"Boot with standard options"  "root=UUID=%s rw quiet"\n"Boot to terminal"            "root=UUID=%s rw init=/sbin/$INIT"\n"Boot with minimal options"   "root=UUID=%s rw"\n' \
                "$ROOT_UUID" "$ROOT_UUID" "$ROOT_UUID" > /mnt/boot/refind_linux.conf
        fi
        ;;
esac


gauge 100 "Installation complete!"

umount -R /mnt 2>/dev/null || true

whiptail --title "$TITLE" --yesno "Installation complete!\n\nReboot now?" 10 50 \
    && reboot || true
