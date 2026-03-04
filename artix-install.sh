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

whiptail --title "$TITLE" --msgbox "Welcome to the Artix Linux Installer

This script will guide you through a minimal, bloat-free
installation of Artix Linux 

You will be asked to configure:
  - Disk, filesystem and swap
  - Locale, timezone and keyboard layout
  - Hostname and user account
  - Desktop environment (or CLI-only)
  - Kernel and bootloader

WARNING: This will erase the selected disk entirely.
Make sure you have backups before continuing.

Press Enter to begin." 22 60

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
# =========================
# INIT SYSTEM
# =========================
INIT=$(whiptail --title "$TITLE" --menu "Init System" 12 60 2 \
    "dinit"  "dinit  -- fast, dependency-based (recommended)" \
    "openrc" "openrc -- traditional, widely supported" \
    3>&1 1>&2 2>&3) || exit 1

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
# ENCRYPTION
# =========================
ENCRYPT=0
REAL_ROOT=""
LUKS_CMDLINE=""
if whiptail --title "$TITLE" --yesno "Enable full disk encryption (LUKS2)?

You will be prompted for a passphrase.
You must enter it on every boot." 12 60; then
    ENCRYPT=1
    LUKS_PW=$(get_password "Encryption Passphrase")
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
        "Select DE/WM (space to toggle, enter to confirm)" 28 70 12 \
        "Plasma"   "KDE Plasma"               OFF \
        "XFCE"     "XFCE4"                    OFF \
        "LXQt"     "LXQt"                     OFF \
        "i3"       "i3wm"                     OFF \
        "XMonad"   "XMonad"                   OFF \
        "Openbox"  "Openbox"                  OFF \
        "Fluxbox"  "Fluxbox"                  OFF \
        "IceWM"    "IceWM"                    OFF \
        "Hyprland" "Hyprland (Wayland)"       OFF \
        "Moksha"   "Moksha"                   OFF \
        "Cosmic"   "COSMIC [EXPERIMENTAL]"    OFF \
        3>&1 1>&2 2>&3) || exit 1
    DE_CHOICES=$(echo "$DE_CHOICES" | tr -d '"')
    if [ -z "$DE_CHOICES" ]; then
        whiptail --title "$TITLE" --msgbox "Nothing selected, defaulting to CLI." 8 50
        DE_CHOICES="CLI"
    fi

    PLASMA_EXTRAS=0; XFCE_EXTRAS=0; I3_EXTRAS=0
    OPENBOX_EXTRAS=0; FLUXBOX_EXTRAS=0; ICEWM_EXTRAS=0; HYPRLAND_EXTRAS=0
    if echo "$DE_CHOICES" | grep -qw "Plasma"; then
        whiptail --title "$TITLE" --yesno \
            "Install KDE apps?\n\ndolphin  — file manager\nkonsole  — terminal\nkate     — text editor\nark      — archive manager\nokular   — document viewer\ngwenview — image viewer\nkcalc    — calculator\nfirefox  — web browser\nfastfetch — system info" \
            20 55 && PLASMA_EXTRAS=1 || true
    fi
    if echo "$DE_CHOICES" | grep -qw "XFCE"; then
        whiptail --title "$TITLE" --yesno \
            "Install XFCE extras?\n\nxfce4-goodies — panel plugins, thunar plugins,\nscreenshot tool, archive manager, media player\nfirefox        — web browser\nfastfetch      — system info" \
            14 58 && XFCE_EXTRAS=1 || true
    fi
    if echo "$DE_CHOICES" | grep -qw "i3"; then
        whiptail --title "$TITLE" --yesno \
            "Install i3 extras?\n\ndmenu     — application launcher\nxterm     — basic terminal\nfirefox   — web browser\nfastfetch — system info" \
            13 50 && I3_EXTRAS=1 || true
    fi
    if echo "$DE_CHOICES" | grep -qw "Openbox"; then
        whiptail --title "$TITLE" --yesno \
            "Install Openbox extras?\n\ntint2     — taskbar/panel\npicom     — compositor\nrofi      — app launcher\nfirefox   — web browser\nfastfetch — system info" \
            15 52 && OPENBOX_EXTRAS=1 || true
    fi
    if echo "$DE_CHOICES" | grep -qw "Fluxbox"; then
        whiptail --title "$TITLE" --yesno \
            "Install Fluxbox extras?\n\nfeh       — wallpaper setter\npicom     — compositor\nrofi      — app launcher\nfirefox   — web browser\nfastfetch — system info" \
            14 52 && FLUXBOX_EXTRAS=1 || true
    fi
    if echo "$DE_CHOICES" | grep -qw "IceWM"; then
        whiptail --title "$TITLE" --yesno \
            "Install IceWM extras?\n\niceconf   — graphical config tool\nfeh       — wallpaper setter\nrofi      — app launcher\nfirefox   — web browser\nfastfetch — system info" \
            14 52 && ICEWM_EXTRAS=1 || true
    fi
    if echo "$DE_CHOICES" | grep -qw "Hyprland"; then
        whiptail --title "$TITLE" --yesno \
            "Install Hyprland extras?\n\nwaybar    — status bar\nwofi      — app launcher\nswaylock  — screen locker\ngrim+slurp — screenshots\nfirefox   — web browser\nfastfetch — system info" \
            16 56 && HYPRLAND_EXTRAS=1 || true
    fi
fi

# =========================
# KERNEL
# =========================
KERNEL_CHOICES=$(whiptail --title "$TITLE" --checklist \
    "Select kernel(s)" 20 70 5 \
    "linux"         "Standard"                                        ON  \
    "linux-lts"     "LTS — long term support"                         OFF \
    "linux-zen"     "Zen — desktop optimised"                         OFF \
    "linux-lqx"     "Liquorix — low latency + MuQSS scheduler"        OFF \
    "linux-cachyos" "CachyOS — BORE scheduler + perf (adds CachyOS repo)" OFF \
    3>&1 1>&2 2>&3) || exit 1
KERNEL_CHOICES=$(echo "$KERNEL_CHOICES" | tr -d '"')
[ -z "$KERNEL_CHOICES" ] && KERNEL_CHOICES="linux"
FIRST_KERNEL=$(echo "$KERNEL_CHOICES" | awk '{print $1}')

# =========================
# BOOTLOADER
# =========================
if [ "$UEFI" = "1" ]; then
    BOOT=$(whiptail --title "$TITLE" --menu "Bootloader" 12 60 3 \
        "grub"   "GRUB2 (most compatible, required for dual-boot)" \
        "limine" "Limine (fast, minimal)" \
        "refind" "rEFInd (graphical)" \
        3>&1 1>&2 2>&3) || exit 1
else
    BOOT="grub"  # BIOS systems only support GRUB
fi

# =========================
# XLIBRE / XORG
# =========================
USE_XLIBRE=0
if [ "$DE_CHOICES" != "CLI" ] && ! echo "$DE_CHOICES" | grep -qw "Cosmic" && ! echo "$DE_CHOICES" | grep -qw "Hyprland"; then
    if whiptail --title "$TITLE" --yesno \
        "Use XLibre instead of Xorg?\n\nXLibre is Artix's actively maintained Xorg fork.\nFeatures: TearFree by default, cleaner codebase.\nInstalled from the galaxy-gremlins repo.\n\nRecommended for bare WMs. Choose No for standard Xorg." \
        14 60; then
        USE_XLIBRE=1
    fi
fi

# =========================
# NETWORK STACK
# =========================
NET_CHOICE=$(whiptail --title "$TITLE" --menu \
    "Network Stack\n\nNetworkManager is heavy (~30MB).\nLighter options save significant RAM at idle." \
    15 65 3 \
    "dhcpcd" "dhcpcd  -- ethernet only, ~2MB" \
    "iwd"    "iwd     -- wifi + ethernet, ~5MB" \
    "NM"     "NetworkManager -- full featured, ~30MB" \
    3>&1 1>&2 2>&3) || NET_CHOICE="NM"


# =========================
# PARTITION
# =========================
# =========================
# =========================
# TUI PARTITION MANAGER
# =========================
PART_DEVS=()
PART_SIZES=()
PART_TYPES=()
DISK_SIZE=$(lsblk -bdno SIZE "$DISK" 2>/dev/null || echo 0)
DISK_SIZE_GB=$(( DISK_SIZE / 1024 / 1024 / 1024 ))
EFI=""
ROOT=""
DUALBOOT=0


while true; do
    TABLE=""
    for i in "${!PART_DEVS[@]}"; do
        TABLE+="${PART_DEVS[$i]}|${PART_SIZES[$i]}GB|${PART_TYPES[$i]}  "
    done
    [ -z "$TABLE" ] && TABLE="(no partitions defined yet)"

    [ "$UEFI" = "1" ] && _AUTO_DESC="Auto layout — 1GB EFI + rest as root (wipes disk)" \
                      || _AUTO_DESC="Auto layout — full disk as root (wipes disk)"
    MENU_ARGS=(
        "auto"     "$_AUTO_DESC"
        "add"      "Add partition"
        "delete"   "Delete last partition"
        "clear"    "Clear all partitions"
        "done"     "Write and continue"
    )
    [ "$UEFI" = "1" ] && MENU_ARGS+=( "dualboot" "Dual-boot — use existing EFI + pick root" )

    ACTION=$(whiptail --title "$TITLE" --menu \
        "Disk: $DISK (${DISK_SIZE_GB}GB)   Layout: $TABLE" \
        20 76 7 \
        "${MENU_ARGS[@]}" \
        3>&1 1>&2 2>&3) || continue

    case "$ACTION" in
        auto)
            PART_DEVS=()
            PART_SIZES=()
            PART_TYPES=()
            DUALBOOT=0
            [[ "$DISK" =~ [0-9]$ ]] && P="p" || P=""
            if [ "$UEFI" = "1" ]; then
                PART_DEVS=( "${DISK}${P}1" "${DISK}${P}2" )
                PART_SIZES=( "1" "0" )
                PART_TYPES=( "EFI" "root" )
            else
                PART_DEVS=( "${DISK}${P}1" )
                PART_SIZES=( "0" )
                PART_TYPES=( "root" )
            fi
            ;;
        dualboot)
            DUALBOOT=1
            PART_DEVS=()
            PART_SIZES=()
            PART_TYPES=()
            # Show all partitions on all disks for EFI selection
            mapfile -t allparts < <(lsblk -pno NAME,SIZE,FSTYPE,PARTTYPE | \
                grep -v '^/dev/[a-z]*[[:space:]]' | \
                awk '{print $1; printf "%s %s %s\n", $2, ($3=="" ? "unformatted" : $3), ($4=="" ? "" : "[EFI]")}')
            EFI=$(whiptail --title "$TITLE" --menu \
                "Dual-boot: Select existing EFI partition\n(This is your Windows/existing ESP — do NOT format it)" \
                18 72 10 "${allparts[@]}" 3>&1 1>&2 2>&3) || continue
            # Show free/unformatted partitions for root
            mapfile -t rootparts < <(lsblk -pno NAME,SIZE,FSTYPE "$DISK" | \
                grep -v "^$DISK " | \
                awk '{print $1; printf "%s %s\n", $2, ($3=="" ? "unformatted" : $3)}')
            ROOT=$(whiptail --title "$TITLE" --menu \
                "Dual-boot: Select partition for Artix root\n(This will be formatted as $FS)" \
                18 72 10 "${rootparts[@]}" 3>&1 1>&2 2>&3) || continue
            whiptail --title "$TITLE" --msgbox \
                "Dual-boot configured:\n\n  EFI  : $EFI  (will NOT be formatted)\n  Root : $ROOT (will be formatted as $FS)\n\nArtix bootloader entry will be added to the existing ESP.\nos-prober will detect your other OS automatically." \
                14 65
            break
            ;;
        add)
            PSIZE=$(whiptail --title "$TITLE" --inputbox \
                "Partition size in GB\n(0 = fill remaining space on disk)" \
                10 55 "" 3>&1 1>&2 2>&3) || continue
            PTYPE=$(whiptail --title "$TITLE" --menu "Partition type" 12 45 4 \
                "EFI"  "EFI System Partition (UEFI only)" \
                "root" "Root filesystem" \
                "swap" "Swap partition" \
                "data" "Extra data partition" \
                3>&1 1>&2 2>&3) || continue
            if [ "$PTYPE" = "EFI" ] && [ "$UEFI" = "0" ]; then
                whiptail --title "$TITLE" --msgbox "EFI partitions are not used on BIOS systems." 8 52
                continue
            fi
            PIDX=$(( ${#PART_DEVS[@]} + 1 ))
            [[ "$DISK" =~ [0-9]$ ]] && P="p" || P=""
            PART_DEVS+=( "${DISK}${P}${PIDX}" )
            PART_SIZES+=( "$PSIZE" )
            PART_TYPES+=( "$PTYPE" )
            ;;
        delete)
            if [ ${#PART_DEVS[@]} -gt 0 ]; then
                unset 'PART_DEVS[-1]'
                unset 'PART_SIZES[-1]'
                unset 'PART_TYPES[-1]'
            fi
            ;;
        clear)
            PART_DEVS=()
            PART_SIZES=()
            PART_TYPES=()
            DUALBOOT=0
            ;;
        done)
            [ "$DUALBOOT" = "1" ] && break
            EFI_COUNT=0; ROOT_COUNT=0
            for t in "${PART_TYPES[@]}"; do
                [ "$t" = "EFI" ]  && EFI_COUNT=$(( EFI_COUNT + 1 ))
                [ "$t" = "root" ] && ROOT_COUNT=$(( ROOT_COUNT + 1 ))
            done
            if [ "$UEFI" = "1" ] && [ "$EFI_COUNT" -ne 1 ]; then
                whiptail --title "$TITLE" --msgbox \
                    "UEFI requires exactly one EFI partition.\nCurrent: ${EFI_COUNT}x EFI." 8 55
                continue
            fi
            if [ "$ROOT_COUNT" -ne 1 ]; then
                whiptail --title "$TITLE" --msgbox \
                    "You need exactly one root partition.\nCurrent: ${ROOT_COUNT}x root." 8 55
                continue
            fi
            for i in "${!PART_TYPES[@]}"; do
                [ "${PART_TYPES[$i]}" = "EFI" ]  && EFI="${PART_DEVS[$i]}"
                [ "${PART_TYPES[$i]}" = "root" ] && ROOT="${PART_DEVS[$i]}"
            done
            break
            ;;
    esac
done

if [ "$DUALBOOT" = "0" ]; then
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
    # Dual-boot — never touch EFI, only format root
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

# =========================
# PROGRESS
# =========================
# Print section headers during install
gauge() {
    echo ""
    echo "==> ${2}"
    echo ""
}


gauge 2 "Partitioning disk..."

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
# CPU microcode — exclusive detection
if grep -qi "intel" /proc/cpuinfo; then
    UCODE="intel-ucode"
elif grep -qi "amd" /proc/cpuinfo; then
    UCODE="amd-ucode"
else
    UCODE=""
fi

if lspci | grep -qi nvidia; then
    GPU="nvidia nvidia-utils"
elif lspci | grep -qiE "amd|radeon"; then
    GPU="mesa vulkan-radeon"
else
    GPU="mesa"
fi

# Bare WMs don't use GL at all — modesetting DDX only needs libdrm which
# is already a kernel dependency. Skip mesa entirely to avoid pulling in LLVM.
BARE_WM_ONLY=1
FULL_DES="Plasma XFCE LXQt Moksha Cosmic Hyprland i3 XMonad"
for _de in $FULL_DES; do
    if echo "$DE_CHOICES" | grep -qw "$_de"; then
        BARE_WM_ONLY=0
        break
    fi
done
[ "$DE_CHOICES" = "CLI" ] && BARE_WM_ONLY=0  # CLI needs no GPU at all
if [ "$BARE_WM_ONLY" = "1" ]; then
    GPU=""
fi

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

# =========================
# CACHYOS REPO (if needed)
# =========================
if echo "$KERNEL_CHOICES" | grep -qw "linux-cachyos"; then
    # Download and install keyring + mirrorlist directly
    curl -sO 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst'
    curl -sO 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-22-1-any.pkg.tar.zst'
    pacman-key --init
    pacman -U --noconfirm cachyos-keyring-*.pkg.tar.zst cachyos-mirrorlist-*.pkg.tar.zst
    rm -f cachyos-keyring-*.pkg.tar.zst cachyos-mirrorlist-*.pkg.tar.zst
    grep -q '\[cachyos\]' /etc/pacman.conf || \
        printf '\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' >> /etc/pacman.conf
    pacman -Sy
    # Verify the binary kernel is actually available from the repo
    if ! pacman -Si linux-cachyos &>/dev/null; then
        whiptail --title "$TITLE" --msgbox "WARNING: CachyOS repo not available.\nFalling back to linux kernel." 10 50
        KERNEL_CHOICES=$(echo "$KERNEL_CHOICES" | sed 's/linux-cachyos/linux/g')
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
    $([ "$INIT" = "dinit" ] && echo "networkmanager networkmanager-dinit" || echo "networkmanager networkmanager-openrc") \
    doas rtkit \
    $XORG_PKGS xdg-user-dirs \
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
    LUKS_CMDLINE="cryptdevice=UUID=$LUKS_UUID=cryptroot root=/dev/mapper/cryptroot"
fi

# Pacman optimizations
sed -i 's/^#Color/Color\nILoveCandy/' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /mnt/etc/pacman.conf
# Block legacy xf86-video DDX drivers — modesetting handles everything
# Prevents DE metapackages from pulling them in as optional deps
grep -q 'xf86-video-amdgpu' /mnt/etc/pacman.conf || \
    sed -i '/^\[options\]/a IgnorePkg = xf86-video-amdgpu xf86-video-intel xf86-video-nouveau xf86-video-fbdev xf86-video-vesa' \
    /mnt/etc/pacman.conf

# Persist Liquorix repo into installed system
if echo "$KERNEL_CHOICES" | grep -qw "linux-lqx"; then
    artix-chroot /mnt pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys 9AE4078033F8024D
    artix-chroot /mnt pacman-key --lsign-key 9AE4078033F8024D
    grep -q 'liquorix.net' /mnt/etc/pacman.conf || \
        printf '\n[liquorix]\nServer = https://liquorix.net/archlinux/$repo/$arch\n' >> /mnt/etc/pacman.conf
    artix-chroot /mnt pacman -Sy --noconfirm
fi

# Persist CachyOS repo into installed system for future updates
if echo "$KERNEL_CHOICES" | grep -qw "linux-cachyos"; then
    artix-chroot /mnt bash -c "
        curl -sO 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst'
        curl -sO 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-22-1-any.pkg.tar.zst'
        pacman -U --noconfirm cachyos-keyring-*.pkg.tar.zst cachyos-mirrorlist-*.pkg.tar.zst
        rm -f cachyos-keyring-*.pkg.tar.zst cachyos-mirrorlist-*.pkg.tar.zst
    "
    grep -q '\[cachyos\]' /mnt/etc/pacman.conf || \
        printf '\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' >> /mnt/etc/pacman.conf
    artix-chroot /mnt pacman -Sy --noconfirm
fi

# Install headers for lqx/cachyos if selected as first kernel
if [ "$FIRST_KERNEL" = "linux-lqx" ]; then
    artix-chroot /mnt pacman -S --noconfirm linux-lqx-headers
elif [ "$FIRST_KERNEL" = "linux-cachyos" ]; then
    : # cachyos bundles headers
fi
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

# =========================
# CHROOT CONFIG
# =========================

# Locale and timezone
gauge 40 "Setting locale..."
artix-chroot /mnt bash -c "echo '$LOCALE UTF-8' >> /etc/locale.gen && locale-gen"
artix-chroot /mnt bash -c "echo 'LANG=$LOCALE' > /etc/locale.conf"
gauge 45 "Setting timezone..."
artix-chroot /mnt bash -c "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc"

# Keyboard
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

# Hostname
gauge 50 "Configuring hostname..."
echo "$HOSTNAME" > /mnt/etc/hostname

# Passwords — read directly from files inside chroot, no encoding needed
# Passwords — pass directly as env vars, no files, no subshells
ROOTPW_B64=$(printf '%s' "$ROOTPW" | base64)
USERPW_B64=$(printf '%s' "$USERPW" | base64)
artix-chroot /mnt bash -c "echo root:\$(echo $ROOTPW_B64 | base64 -d) | chpasswd"
gauge 55 "Creating user account..."
artix-chroot /mnt bash -c "useradd -m -G wheel,audio,video,storage,input '$USERNAME'"
artix-chroot /mnt bash -c "echo $USERNAME:\$(echo $USERPW_B64 | base64 -d) | chpasswd"

# doas — primary privilege escalation
cat > /mnt/etc/doas.conf << 'EOF'
permit persist :wheel
permit nopass :wheel cmd pacman
EOF
chmod 0400 /mnt/etc/doas.conf

# sudoers — uncomment wheel group so sudo works too
if [ -f /mnt/etc/sudoers ]; then
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /mnt/etc/sudoers
else
    mkdir -p /mnt/etc/sudoers.d
    echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
    chmod 0440 /mnt/etc/sudoers.d/wheel
fi

# XDG user dirs
artix-chroot /mnt su -s /bin/bash - "$USERNAME" -c "xdg-user-dirs-update"

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

USER_UID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f3)
USER_GID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f4)

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

# Moksha
mkdir -p /mnt/home/"$USERNAME"/.e/e/applications/startup
cat > /mnt/home/"$USERNAME"/.e/e/applications/startup/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=/usr/local/bin/start-pipewire
EOF
fi # end NEED_AUDIO

chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"

# Bare WMs use startx from TTY1 — no display manager needed
BARE_WMS="i3 XMonad Openbox Fluxbox IceWM"
for _wm in $BARE_WMS; do
    if echo "$DE_CHOICES" | grep -qw "$_wm"; then
        # .bash_profile launches startx only on TTY1
        cat >> /mnt/home/"$USERNAME"/.bash_profile << 'EOF'
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx
EOF
        chown "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.bash_profile
        # Override agetty-tty1 to autologin
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
# =========================
# DESKTOP INSTALL
# =========================
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
            # plasma-desktop instead of plasma group — cuts ~300MB and 0.5GB RAM usage
            # Hand-picked essentials only: shell, compositor, settings, network, audio,
            # notifications, power management, display config, bluetooth, theming
            artix-chroot /mnt pacman -S --noconfirm \
                plasma-desktop        `# core desktop shell` \
                kwin                  `# compositor/window manager` \
                plasma-pa             `# audio volume applet` \
                plasma-nm             `# network manager applet` \
                powerdevil            `# power management` \
                bluedevil             `# bluetooth` \
                kscreen               `# display configuration` \
                ksystemstats          `# system monitor backend` \
                kde-gtk-config        `# GTK app theming integration` \
                breeze                `# default theme` \
                breeze-gtk            `# GTK breeze theme` \
                knotifications        `# notification framework` \
                kwallet               `# credential storage` \
                polkit-kde-agent      `# privilege escalation dialogs` \
                xdg-desktop-portal-kde \
                sddm-kcm              `# SDDM settings in system settings`
            if [ "${PLASMA_EXTRAS:-0}" = "1" ]; then
                artix-chroot /mnt pacman -S --noconfirm \
                    dolphin konsole kate ark okular gwenview kcalc firefox fastfetch
            fi
            ;;
        XFCE)
            artix-chroot /mnt pacman -S --noconfirm \
                xfce4 xdg-desktop-portal-gtk pavucontrol
            if [ "${XFCE_EXTRAS:-0}" = "1" ]; then
                artix-chroot /mnt pacman -S --noconfirm xfce4-goodies firefox fastfetch
            fi
            ;;
        LXQt)
            artix-chroot /mnt pacman -S --noconfirm lxqt pavucontrol
            ;;
        i3)
            artix-chroot /mnt pacman -S --noconfirm i3-wm
            if [ "${I3_EXTRAS:-0}" = "1" ]; then
                artix-chroot /mnt pacman -S --noconfirm dmenu xterm firefox fastfetch
            fi
            ;;
        XMonad)
            # xmonad/xmonad-contrib live in Arch's [extra], not Artix repos
            # Enable Arch repos via artix-archlinux-support first
            artix-chroot /mnt pacman -S --noconfirm artix-archlinux-support
            grep -q '\[extra\]' /mnt/etc/pacman.conf || \
                printf '\n# Arch repos (needed for xmonad)\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' \
                >> /mnt/etc/pacman.conf
            artix-chroot /mnt pacman -Sy --noconfirm
            artix-chroot /mnt pacman -S --noconfirm \
                xmonad xmonad-contrib \
                thunar polybar picom st git
            # Clone dotfiles into ~/.config
            artix-chroot /mnt bash -c "
                mkdir -p /home/$USERNAME/.config
                git clone https://github.com/feribsd/xmonad-dotfiles.git /tmp/xmonad-dotfiles
                cp -r /tmp/xmonad-dotfiles/. /home/$USERNAME/.config/
                rm -rf /tmp/xmonad-dotfiles
                chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/
            "
            ;;
        Openbox)
            artix-chroot /mnt pacman -S --noconfirm openbox xterm
            if [ "${OPENBOX_EXTRAS:-0}" = "1" ]; then
                artix-chroot /mnt pacman -S --noconfirm tint2 picom rofi firefox fastfetch
            fi
            ;;
        Fluxbox)
            artix-chroot /mnt pacman -S --noconfirm fluxbox xterm
            if [ "${FLUXBOX_EXTRAS:-0}" = "1" ]; then
                artix-chroot /mnt pacman -S --noconfirm feh picom rofi firefox fastfetch
            fi
            ;;
        IceWM)
            artix-chroot /mnt pacman -S --noconfirm icewm xterm ttf-dejavu
            artix-chroot /mnt fc-cache -fv &>/dev/null
            if [ "${ICEWM_EXTRAS:-0}" = "1" ]; then
                artix-chroot /mnt pacman -S --noconfirm iceconf feh rofi firefox fastfetch
            fi
            mkdir -p /mnt/home/"$USERNAME"/.config/icewm
            # Minimal Xorg config — prevents zen kernel DRM over-allocation
            mkdir -p /mnt/etc/X11/xorg.conf.d
            cat > /mnt/etc/X11/xorg.conf.d/10-icewm-minimal.conf << 'EOF'
Section "ServerFlags"
    Option "NoPM"             "true"
    Option "NoTrapSignals"    "false"
    Option "BlankTime"        "0"
    Option "StandbyTime"      "0"
    Option "SuspendTime"      "0"
    Option "OffTime"          "0"
EndSection

Section "Device"
    Identifier "GPU"
    Driver     "modesetting"
    Option     "AccelMethod"    "glamor"
    Option     "DRI"            "3"
    Option     "TearFree"       "true"
    Option     "PageFlip"       "true"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device     "GPU"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080"
    EndSubSection
EndSection
EOF
            cat > /mnt/home/"$USERNAME"/.xinitrc << 'EOF'
#!/bin/sh
# Kill any stale X locks
rm -f /tmp/.X*-lock /tmp/.X11-unix/X*

# Disable screen blanking and power management
xset s off
xset -dpms
xset s noblank

# Font paths
xset fp+ /usr/share/fonts/TTF
xset fp+ /usr/share/fonts/dejavu
xset fp rehash

exec icewm-session
EOF
            chmod +x /mnt/home/"$USERNAME"/.xinitrc
            ;;
        Hyprland)
            artix-chroot /mnt pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland pavucontrol
            # Hyprland pipewire autostart via hyprland.conf exec-once
            # .xprofile is X11-only and does not run under Wayland/greetd
            mkdir -p /mnt/home/"$USERNAME"/.config/hypr
            cat >> /mnt/home/"$USERNAME"/.config/hypr/hyprland.conf << 'HYPREOF'
exec-once = /usr/local/bin/start-pipewire
HYPREOF
            chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.config/hypr
            if [ "${HYPRLAND_EXTRAS:-0}" = "1" ]; then
                artix-chroot /mnt pacman -S --noconfirm waybar wofi swaylock grim slurp firefox fastfetch
            fi
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
            artix-chroot /mnt pacman -S --noconfirm moksha-artix pavucontrol
            ;;
        Cosmic)
            artix-chroot /mnt bash -c "
                grep -q '\[galaxy\]' /etc/pacman.conf || printf '\n[galaxy]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
                pacman -Sy --noconfirm
            "
            artix-chroot /mnt pacman -S --noconfirm \
                cosmic-session cosmic-comp cosmic-greeter \
                $([ "$INIT" = "dinit" ] && echo "greetd greetd-dinit" || echo "greetd greetd-openrc") \
                xdg-desktop-portal-cosmic xdg-user-dirs-gtk \
                cosmic-terminal cosmic-files cosmic-text-editor \
                cosmic-player cosmic-store cosmic-screenshot \
                cosmic-settings upower pavucontrol firefox
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

# sudo symlink — after all packages installed to avoid conflicts
# kdesu and various DE tools hardcode sudo
[ ! -e /mnt/usr/bin/sudo ] && artix-chroot /mnt ln -s /usr/bin/doas /usr/bin/sudo || true

gauge 85 "Enabling services..."
# =========================
# INIT SERVICES
# =========================

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

# =========================
# DONE
# =========================
gauge 100 "Installation complete!"

umount -R /mnt 2>/dev/null || true

whiptail --title "$TITLE" --yesno "Installation complete!\n\nReboot now?" 10 50 \
    && reboot || true
