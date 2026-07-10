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
# TUI THEME
# monochrome base + red accents + dark gray selection
# =========================
export NEWT_COLORS='
root=white,black
border=white,black
window=white,black
shadow=black,black
title=red,black
button=black,red
actbutton=white,red
compactbutton=white,black
checkbox=white,black
actcheckbox=black,white
entry=white,black
label=white,black
listbox=white,black
actlistbox=white,black
sellistbox=red,black
actsellistbox=black,red
textbox=white,black
acttextbox=white,black
helpline=black,white
roottext=white,black
emptyscale=white,black
fullscale=red,black
disentry=white,black
'

declare -A PART_FS
EXTRA_MOUNTS=()

# fs_key: sanitize a device path to use as assoc array key (/dev/sda1 -> dev_sda1)
fs_key() { echo "${1//\//_}" | sed 's/^_//'; }

# =========================
# TEST / FAST MODE
# =========================
# Pass --test as first arg to skip all prompts and do a fast CLI install
# Uses: first disk found, ext4, no swap, no encrypt, dinit, NM, linux kernel,
#       AMD cpu/gpu, GRUB, no DE, hostname=artix, user=user, pw=idk
TEST_MODE=0
if [ "${1:-}" = "--test" ]; then
  TEST_MODE=1
  DISK=$(lsblk -dpno NAME | grep -v loop | head -1)
  FS="ext4"
  SWAP="None"
  ENCRYPT=0
  REAL_ROOT=""
  LUKS_CMDLINE=""
  LUKS_PW=""
  INIT="dinit"
  LOCALE="en_US.UTF-8"
  TIMEZONE="Europe/London"
  KB_LAYOUT="us"
  VC_KEYMAP="us"
  HOSTNAME="artix"
  USERNAME="user"
  USER_SHELL="/bin/bash"
  ROOTPW="idk"
  USERPW="idk"
  INSTALL_TYPE="CLI"
  DE_CHOICES="CLI"
  KERNEL_CHOICES="linux"
  FIRST_KERNEL="linux"
  CPU_VENDOR="amd"
  UCODE="amd-ucode"
  GPU_CHOICE="amd"
  GPU="mesa vulkan-radeon"
  UEFI_ORIG="$UEFI"
  BOOT="grub"
  NET_CHOICE="NM"
  AUDIO_PKGS=""
  PRIV_ESC="doas"
  MULTILIB=0
  ENABLE_ARCH=0
  ENABLE_GALAXY=0
  ENABLE_CACHYOS=0
  BTRFS_SNAPSHOTS=0
  # partition layout
  RICE_WM=0
  [[ "$DISK" =~ (nvme|mmcblk) ]] && P="p" || P=""
  if [ "$UEFI" = "1" ]; then
    PART_DEVS=("${DISK}${P}1" "${DISK}${P}2")
    PART_SIZES=("1" "0")
    PART_TYPES=("EFI" "root")
    EFI="${DISK}${P}1"
    ROOT="${DISK}${P}2"
  else
    PART_DEVS=("${DISK}${P}1")
    PART_SIZES=("0")
    PART_TYPES=("root")
    EFI=""
    ROOT="${DISK}${P}1"
  fi
  DUALBOOT=0
  SWAP_PART=""
  EXTRA_MOUNTS=()
  ZFS_ROOT=0
  echo "==> TEST MODE: disk=$DISK boot=$BOOT uefi=$UEFI"
fi

if [ "$TEST_MODE" = "0" ]; then
  whiptail --title "$TITLE" --msgbox "WARNING: This will erase the selected disk.\nMake sure you have backups.\n\nPress Enter to begin." 10 55
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

# per-partition filesystem picker
pick_fs() {
  local _title="$1" _default="${2:-ext4}"
  whiptail --title "$TITLE" --menu "$_title" 18 65 10 \
    "ext4" "Ext4 — solid, widely supported" \
    "btrfs" "Btrfs — snapshots, compression" \
    "xfs" "XFS — high performance" \
    "f2fs" "F2FS — flash-friendly" \
    "zfs" "ZFS — advanced (needs zfs-dkms)" \
    "jfs" "JFS — low CPU journaled FS" \
    "nilfs2" "NILFS2 — continuous snapshots" \
    "vfat" "FAT32 — for EFI/compatibility" \
    "exfat" "exFAT — large files, cross-platform" \
    "ntfs" "NTFS — Windows compatibility" \
    3>&1 1>&2 2>&3
}

# =========================
# =========================
# INIT SYSTEM
# =========================
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

if [ "$TEST_MODE" = "0" ]; then

  # Step-based Q&A with back navigation
  # Each step sets variables; pressing Cancel goes back one step
  STEP=1
  STEP_MAX=14

  # defaults (overwritten by each step)
  INIT="dinit"
  DISK=""
  FS="ext4"
  SWAP="None"
  SWAP_SIZE_GB=4
  SWAP_SIZE_MB=4096
  ENCRYPT=0
  REAL_ROOT=""
  LUKS_CMDLINE=""
  LUKS_PW=""
  LOCALE="en_US.UTF-8"
  TIMEZONE="Europe/London"
  KB_LAYOUT="us"
  HOSTNAME="artix"
  USERNAME="user"
  USER_SHELL="/bin/bash"
  ROOTPW=""
  USERPW=""
  INSTALL_TYPE="CLI"
  DE_CHOICES="CLI"
  KERNEL_CHOICES="linux"
  FIRST_KERNEL="linux"
  CPU_VENDOR="amd"
  UCODE="amd-ucode"
  GPU_CHOICE="vm"
  GPU="mesa"
  BOOT="grub"
  NET_CHOICE="NM"
  PRIV_ESC="doas"
  MULTILIB=0
  ENABLE_ARCH=0
  ENABLE_GALAXY=0
  ENABLE_CACHYOS=0
  BTRFS_SNAPSHOTS=0

  RICE_WM=0
  RAM_HALF_GB=$(((RAM_KB / 1024 / 1024 + 1) / 2))
  ((RAM_HALF_GB < 1)) && RAM_HALF_GB=1
  ((RAM_HALF_GB > 16)) && RAM_HALF_GB=16

  while true; do
    case "$STEP" in

    1) # Init system
      _v=$(whiptail --title "$TITLE" --menu "Init System  [1/$STEP_MAX]" 16 65 4 \
        "dinit" "dinit  — fast, dependency-based (recommended)" \
        "openrc" "openrc — traditional, widely supported" \
        "runit" "runit  — minimal, supervision-based" \
        "s6" "s6     — small, fast, supervision-based" \
        3>&1 1>&2 2>&3) || exit 1
      INIT="$_v"
      STEP=$((STEP + 1))
      ;;

    2) # Disk
      mapfile -t disklist < <(lsblk -dpno NAME,SIZE | grep -v loop | awk '{print $1; print $2}')
      _v=$(whiptail --title "$TITLE" --menu "Select Disk  [2/$STEP_MAX]" 20 70 10 \
        "${disklist[@]}" 3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      DISK="$_v"
      STEP=$((STEP + 1))
      ;;

    3) # Filesystem
      _v=$(whiptail --title "$TITLE" --menu "Root Filesystem  [3/$STEP_MAX]" 16 65 8 \
        "ext4" "Ext4 — solid, widely supported (recommended)" \
        "btrfs" "Btrfs — snapshots, compression, subvolumes" \
        "xfs" "XFS — high performance, large files" \
        "f2fs" "F2FS — flash-friendly (SSDs/NVMe)" \
        "zfs" "ZFS — advanced, needs zfs-dkms (experimental)" \
        "jfs" "JFS — IBM journaled FS, low CPU usage" \
        "nilfs2" "NILFS2 — continuous snapshotting" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      FS="$_v"
      if [ "$FS" = "btrfs" ]; then
        if whiptail --title "$TITLE" --yesno \
          "Enable btrfs snapshots?  [3/$STEP_MAX]\n\nInstalls snapper + snap-pac.\nAuto-snapshots before pacman upgrades.\nAdds snapshot entries to the boot menu." \
          11 65; then
          BTRFS_SNAPSHOTS=1
        else
          BTRFS_SNAPSHOTS=0
        fi
      fi
      STEP=$((STEP + 1))
      ;;

    4) # Swap
      _v=$(whiptail --title "$TITLE" --menu "Swap  [4/$STEP_MAX]" 14 65 5 \
        "Zram" "zram — compressed RAM swap (recommended)" \
        "Swapfile" "Swapfile on root partition" \
        "Both" "Zram + Swapfile" \
        "Partition" "Dedicated swap partition (auto layout only)" \
        "None" "No swap" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      SWAP="$_v"
      # Warn about swapfile + LUKS encryption interaction
      if [ "$ENCRYPT" = "1" ] && [[ "$SWAP" =~ Swapfile|Both ]]; then
        whiptail --title "$TITLE" --msgbox \
          "⚠️  WARNING: Swapfile + LUKS Encryption\n\nSwapfiles on encrypted root can cause issues.\n\nRecommendations:\n• Use Zram (safer with encryption)\n• Create separate unencrypted swap partition\n• Use no swap\n\nProceeding with swapfile — ensure sufficient RAM." \
          13 65
      fi
      if [[ "$SWAP" =~ Swapfile|Both|Partition ]]; then
        SWAP_MENU_ARGS=()
        for SZ in 1 2 4 8 16; do
          ((SZ == RAM_HALF_GB)) &&
            SWAP_MENU_ARGS+=("$SZ" "${SZ}GB  <- recommended") ||
            SWAP_MENU_ARGS+=("$SZ" "${SZ}GB")
        done
        _v=$(whiptail --title "$TITLE" --menu "Swapfile Size  [4/$STEP_MAX]" 13 60 5 \
          "${SWAP_MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || continue
        SWAP_SIZE_GB="$_v"
        SWAP_SIZE_MB=$((SWAP_SIZE_GB * 1024))
      fi
      STEP=$((STEP + 1))
      ;;

    5) # Encryption
      if whiptail --title "$TITLE" --yesno \
        "Encryption  [5/$STEP_MAX]\n\nEnable full disk encryption (LUKS2)?\nYou will enter a passphrase on every boot." \
        10 60; then
        ENCRYPT=1
        LUKS_PW=$(get_password "Encryption Passphrase")
      else
        ENCRYPT=0
        LUKS_PW=""
      fi
      STEP=$((STEP + 1))
      ;;

    6) # Locale + Timezone + Keyboard (one screen each, all in step 6 — back returns to step 5)
      _v=$(whiptail --title "$TITLE" --menu "Locale  [6/$STEP_MAX]" 20 60 12 \
        "en_US.UTF-8" "English (US)" "en_GB.UTF-8" "English (UK)" \
        "en_AU.UTF-8" "English (Australia)" "en_CA.UTF-8" "English (Canada)" \
        "de_DE.UTF-8" "German" "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" "it_IT.UTF-8" "Italian" \
        "pt_BR.UTF-8" "Portuguese (Brazil)" "pt_PT.UTF-8" "Portuguese (Portugal)" \
        "ru_RU.UTF-8" "Russian" "pl_PL.UTF-8" "Polish" \
        "nl_NL.UTF-8" "Dutch" "sv_SE.UTF-8" "Swedish" \
        "nb_NO.UTF-8" "Norwegian" "da_DK.UTF-8" "Danish" \
        "fi_FI.UTF-8" "Finnish" "hu_HU.UTF-8" "Hungarian" \
        "cs_CZ.UTF-8" "Czech" "sk_SK.UTF-8" "Slovak" \
        "hr_HR.UTF-8" "Croatian" "ro_RO.UTF-8" "Romanian" \
        "uk_UA.UTF-8" "Ukrainian" "tr_TR.UTF-8" "Turkish" \
        "ja_JP.UTF-8" "Japanese" "ko_KR.UTF-8" "Korean" \
        "zh_CN.UTF-8" "Chinese (Simplified)" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      LOCALE="$_v"
      # Try to auto-detect timezone from IP geolocation
      _tz_auto=$(curl -s "https://ipapi.co/json/" 2>/dev/null | grep -o '"timezone":"[^"]*' | cut -d'"' -f4)
      _tz_default="UTC"
      [ -n "$_tz_auto" ] && _tz_default="$_tz_auto"

      _v=$(whiptail --title "$TITLE" --menu "Timezone  [6/$STEP_MAX]\n\n(Auto-detected: $_tz_default)" 20 62 12 \
        "Europe/London" "UK" "Europe/Dublin" "Ireland" \
        "Europe/Paris" "France/CET" "Europe/Berlin" "Germany" \
        "Europe/Amsterdam" "Netherlands" "Europe/Madrid" "Spain" \
        "Europe/Rome" "Italy" "Europe/Warsaw" "Poland" \
        "Europe/Stockholm" "Sweden" "Europe/Oslo" "Norway" \
        "Europe/Copenhagen" "Denmark" "Europe/Helsinki" "Finland" \
        "Europe/Budapest" "Hungary" "Europe/Prague" "Czech Republic" \
        "Europe/Bratislava" "Slovakia" "Europe/Zagreb" "Croatia" \
        "Europe/Bucharest" "Romania" "Europe/Kiev" "Ukraine" \
        "Europe/Istanbul" "Turkey" "Europe/Moscow" "Russia" \
        "America/New_York" "US Eastern" "America/Chicago" "US Central" \
        "America/Denver" "US Mountain" "America/Los_Angeles" "US Pacific" \
        "America/Toronto" "Canada Eastern" "America/Sao_Paulo" "Brazil" \
        "Asia/Tokyo" "Japan" "Asia/Seoul" "Korea" \
        "Asia/Kuala_Lumpur" "Malaysia" "Asia/Singapore" "Singapore" \
        "Asia/Shanghai" "China" "Australia/Sydney" "Australia" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      TIMEZONE="$_v"
      _v=$(whiptail --title "$TITLE" --menu "Keyboard Layout  [6/$STEP_MAX]" 20 60 12 \
        "us" "English (US)" "gb" "English (UK)" \
        "us-intl" "English (Intl)" "de" "German" \
        "de-latin1" "German (L1)" "fr" "French" \
        "fr-bepo" "French (Bepo)" "es" "Spanish" \
        "it" "Italian" "pt" "Portuguese" \
        "br" "Portuguese (BR)" "br-abnt2" "Portuguese (ABNT2)" \
        "ru" "Russian" "pl" "Polish" \
        "nl" "Dutch" "sv" "Swedish" \
        "no" "Norwegian" "dk" "Danish" \
        "fi" "Finnish" "hu" "Hungarian" \
        "cz" "Czech" "cz-qwerty" "Czech (QWERTY)" \
        "sk" "Slovak" "hr" "Croatian" \
        "ro" "Romanian" "bg" "Bulgarian" \
        "gr" "Greek" "tr" "Turkish" \
        "ua" "Ukrainian" "dvorak" "Dvorak" \
        "colemak" "Colemak" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      KB_LAYOUT="$_v"
      STEP=$((STEP + 1))
      ;;

    7) # Hostname + username + shell
      _v=$(whiptail --title "$TITLE" --inputbox "Hostname  [7/$STEP_MAX]" 10 60 "${HOSTNAME:-artix}" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      [[ "$_v" =~ ^[a-zA-Z0-9\-]+$ ]] && HOSTNAME="$_v" ||
        {
          whiptail --title "$TITLE" --msgbox "Invalid hostname. Use letters, numbers, hyphens only." 8 50
          continue
        }
      _v=$(whiptail --title "$TITLE" --inputbox "Username  [7/$STEP_MAX]" 10 60 "${USERNAME:-user}" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      [[ "$_v" =~ ^[a-z][a-z0-9_\-]*$ ]] && USERNAME="$_v" ||
        {
          whiptail --title "$TITLE" --msgbox "Invalid username. Use lowercase letters, numbers, _ or -." 8 55
          continue
        }
      _v=$(whiptail --title "$TITLE" --menu "Login Shell  [7/$STEP_MAX]" 11 60 4 \
        "bash" "Bash — POSIX shell" \
        "zsh" "Zsh — powerful interactive shell" \
        "fish" "Fish — user-friendly shell" \
        "sh" "Sh — minimal POSIX shell" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      USER_SHELL="/bin/$_v"
      ROOTPW=$(get_password "Root Password  [7/$STEP_MAX]")
      USERPW=$(get_password "User Password  [7/$STEP_MAX]")
      # Validate passwords aren't empty
      if [ -z "$ROOTPW" ] || [ -z "$USERPW" ]; then
        whiptail --title "$TITLE" --msgbox "Error: Passwords cannot be empty.\n\nPlease try again." 8 50
        continue
      fi
      STEP=$((STEP + 1))
      ;;

    8) # Privilege escalation
      _v=$(whiptail --title "$TITLE" --menu "Privilege Escalation  [8/$STEP_MAX]" 12 60 2 \
        "doas" "doas  — minimal, OpenBSD-style (recommended)" \
        "sudo" "sudo  — standard, widely compatible" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      PRIV_ESC="$_v"
      STEP=$((STEP + 1))
      ;;

    9) # Desktop
      _v=$(whiptail --title "$TITLE" --menu "Installation Type  [9/$STEP_MAX]" 10 60 2 \
        "DE" "Desktop Environment / Window Manager" \
        "CLI" "CLI only" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      INSTALL_TYPE="$_v"
      DE_CHOICES="CLI"
      if [ "$INSTALL_TYPE" = "DE" ]; then
        DE_CHOICES=$(whiptail --title "$TITLE" --checklist \
          "Select DE/WM  [9/$STEP_MAX]  (space=toggle)" 22 72 14 \
          "Plasma" "KDE Plasma — modern, feature-rich" OFF \
          "XFCE" "XFCE4 — lightweight, classic" OFF \
          "LXQt" "LXQt — Qt-based lightweight" OFF \
          "GNOME" "GNOME — older version (no systemd support, unmaintained)" OFF \
          "i3" "i3wm — tiling" OFF \
          "bspwm" "bspwm — binary space partition" OFF \
          "XMonad" "XMonad — functional, Haskell-based" OFF \
          "Openbox" "Openbox — highly configurable" OFF \
          "Fluxbox" "Fluxbox — minimal, fast" OFF \
          "IceWM" "IceWM — retro, WindowMaker-style" OFF \
          "Sway" "Sway — i3-like on Wayland" OFF \
          "Hyprland" "Hyprland — modern Wayland compositor" OFF \
          "Moksha" "Moksha — Enlightenment fork" OFF \
          "dwm" "dwm — ultra-minimal (AUR, manual patching)" OFF \
          3>&1 1>&2 2>&3) || {
          STEP=$((STEP - 1))
          continue
        }
        DE_CHOICES=$(echo "$DE_CHOICES" | tr -d '"')
        [ -z "$DE_CHOICES" ] && DE_CHOICES="CLI"
        # Warn about GNOME
        if echo "$DE_CHOICES" | grep -qw "GNOME"; then
          whiptail --title "$TITLE" --msgbox \
            "⚠ GNOME Warning\n\nThis is an older, unmaintained version of GNOME.\nThe Artix project has dropped support because GNOME upstream is heavily dependent on systemd.\n\nYou can still use it, but:\n• Security updates may be limited\n• Some features may not work\n• Upstream patches won't be available\n\nConsider using XFCE, LXQt, or a window manager instead." \
            14 70
        fi
      fi
      STEP=$((STEP + 1))
      ;;

    10) # Kernel + CPU + GPU
      KERNEL_CHOICES=$(whiptail --title "$TITLE" --checklist \
        "Kernel  [10/$STEP_MAX]" 16 70 6 \
        "linux" "Standard" ON \
        "linux-lts" "LTS — long term support" OFF \
        "linux-zen" "Zen — desktop optimised" OFF \
        "linux-lqx" "Liquorix — low latency" OFF \
        "linux-cachyos" "CachyOS — BORE scheduler (adds CachyOS repo)" OFF \
        "linux-xanmod" "XanMod — AUR, compiles from source (~1hr)" OFF \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      KERNEL_CHOICES=$(echo "$KERNEL_CHOICES" | tr -d '"')
      [ -z "$KERNEL_CHOICES" ] && KERNEL_CHOICES="linux"
      FIRST_KERNEL=$(echo "$KERNEL_CHOICES" | awk '{print $1}')
      # XanMod is AUR-only, can't be basestrapped — use linux as base if xanmod is first
      [ "$FIRST_KERNEL" = "linux-xanmod" ] && FIRST_KERNEL="linux"
      _v=$(whiptail --title "$TITLE" --menu "CPU Vendor  [10/$STEP_MAX]" 10 50 3 \
        "intel" "Intel" "amd" "AMD" "other" "Other / VM" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      CPU_VENDOR="$_v"
      case "$CPU_VENDOR" in
      intel) UCODE="intel-ucode" ;; amd) UCODE="amd-ucode" ;; *) UCODE="" ;;
      esac
      _v=$(whiptail --title "$TITLE" --menu "GPU  [10/$STEP_MAX]" 13 60 5 \
        "intel" "Intel iGPU" \
        "amd" "AMD" \
        "nvidia" "Nvidia" \
        "hybrid" "Hybrid Intel+Nvidia" \
        "vm" "VM / none (mesa only)" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      GPU_CHOICE="$_v"
      case "$GPU_CHOICE" in
      intel) GPU="mesa vulkan-intel" ;;
      amd) GPU="mesa vulkan-radeon" ;;
      nvidia) GPU="mesa nvidia-dkms nvidia-utils" ;;
      hybrid) GPU="mesa vulkan-intel nvidia-dkms nvidia-utils" ;;
      vm) GPU="mesa" ;;
      esac
      # If nvidia selected, ask about proprietary vs open source
      if [ "$GPU_CHOICE" = "nvidia" ] || [ "$GPU_CHOICE" = "hybrid" ]; then
        if whiptail --title "$TITLE" --yesno \
          "NVIDIA Drivers  [10/$STEP_MAX]\n\nUse proprietary nvidia drivers?\n\nYes = proprietary (better performance, needs dkms rebuild on kernel updates)\nNo = open source nouveau (may have compatibility issues)" \
          11 70; then
          NVIDIA_DRV="proprietary"
          # GPU already set to nvidia-dkms above
        else
          NVIDIA_DRV="nouveau"
          # Replace nvidia-dkms with nouveau
          GPU=$(echo "$GPU" | sed 's/nvidia-dkms/nouveau/g')
        fi
      fi

      # Detect Broadcom WiFi hardware and prompt for firmware
      if lspci 2>/dev/null | grep -qi "broadcom.*wireless\|bcm.*wireless"; then
        if whiptail --title "$TITLE" --yesno \
          "Broadcom WiFi Detected  [10/$STEP_MAX]\n\nInstall broadcom-wl-dkms driver?\n\nYes = proprietary driver (most compatible)\nNo = use open source alternatives (may not work on all chips)" \
          11 70; then
          GPU="$GPU broadcom-wl-dkms"
        fi
      fi

      # Detect other common firmware needs
      _fw_pkgs=""

      # Intel WiFi (iwlwifi)
      if lspci 2>/dev/null | grep -qi "intel.*wireless\|iwlwifi"; then
        _fw_pkgs="$_fw_pkgs linux-firmware"
      fi

      # Qualcomm/Atheros WiFi
      if lspci 2>/dev/null | grep -qi "qualcomm\|atheros.*wireless\|ath9k\|ath10k"; then
        _fw_pkgs="$_fw_pkgs linux-firmware"
      fi

      # Realtek WiFi/Ethernet
      if lspci 2>/dev/null | grep -qi "realtek.*wireless\|rtl.*\|r8"; then
        _fw_pkgs="$_fw_pkgs linux-firmware"
      fi

      # NVIDIA GPU firmware (nouveau, nvenc)
      if lspci 2>/dev/null | grep -qi "nvidia.*vga\|nvidia.*3d"; then
        _fw_pkgs="$_fw_pkgs linux-firmware"
      fi

      # AMD/ATI GPU firmware
      if lspci 2>/dev/null | grep -qi "amd.*vga\|ati.*vga\|radeon"; then
        _fw_pkgs="$_fw_pkgs linux-firmware"
      fi

      # Sound cards that need firmware
      if lspci 2>/dev/null | grep -qi "sigmatel\|cirrus\|conexant"; then
        _fw_pkgs="$_fw_pkgs linux-firmware"
      fi

      # Add detected firmware packages to GPU string (will be installed with GPU)
      if [ -n "$_fw_pkgs" ]; then
        _detected=$(echo "$_fw_pkgs" | xargs -n1 | sort -u | tr '\n' ' ')
        if whiptail --title "$TITLE" --yesno \
          "Firmware Detected\n\nAuto-detected hardware firmware needed:\n$_detected\n\nInstall?" \
          11 70; then
          GPU="$GPU $_detected"
        fi
      fi

      # Detect other useful packages based on hardware
      _extra_pkgs=""

      # RAID/LVM detection
      if lsblk 2>/dev/null | grep -qi "raid\|dm-"; then
        _extra_pkgs="$_extra_pkgs mdadm lvm2"
      fi

      # NVMe-specific tools
      if lsblk 2>/dev/null | grep -qi "nvme"; then
        _extra_pkgs="$_extra_pkgs nvme-cli"
      fi

      # Encryption utilities already included if ENCRYPT=1, but ensure cryptsetup
      if [ "$ENCRYPT" = "1" ]; then
        _extra_pkgs="$_extra_pkgs cryptsetup"
      fi

      # Add to basestrap if any detected
      if [ -n "$_extra_pkgs" ]; then
        EXTRA_PKGS=$(echo "$_extra_pkgs" | xargs -n1 | sort -u | tr '\n' ' ')
      fi

      # Audio daemon choice (only if desktop DE selected)
      if [ "$INSTALL_TYPE" = "DE" ] && echo "$DE_CHOICES" | grep -qvE "CLI"; then
        _v=$(whiptail --title "$TITLE" --menu \
          "Audio Daemon  [10/$STEP_MAX]\n\nSelect audio server for sound handling:" 13 70 3 \
          "pipewire" "PipeWire — modern, low-latency (recommended)" \
          "pulseaudio" "PulseAudio — traditional, widely compatible" \
          "alsa" "ALSA only — minimal, no daemon" \
          3>&1 1>&2 2>&3) || {
          STEP=$((STEP - 1))
          continue
        }
        AUDIO_DAEMON="$_v"
      else
        AUDIO_DAEMON="none"
      fi

      STEP=$((STEP + 1))
      ;;

    11) # Bootloader
      if [ "$UEFI" = "1" ]; then
        _v=$(whiptail --title "$TITLE" --menu "Bootloader  [11/$STEP_MAX]" 12 65 3 \
          "grub" "GRUB2 — most compatible, required for dual-boot" \
          "limine" "Limine — fast, minimal" \
          "refind" "rEFInd — graphical" \
          3>&1 1>&2 2>&3) || {
          STEP=$((STEP - 1))
          continue
        }
        BOOT="$_v"
      else
        BOOT="grub"
      fi
      STEP=$((STEP + 1))
      ;;

    12) # WM dotfiles / rice
      # Only show if user picked a bare WM (i3, XMonad, Openbox, etc.)
      if echo "$DE_CHOICES" | grep -qE "i3|XMonad|Openbox|Fluxbox|IceWM"; then
        if whiptail --title "$TITLE" --yesno \
          "Window Manager Dotfiles  [12/$STEP_MAX]\n\nInstall minimal riced dotfiles for your WM?\n\nIncludes basic i3/bspwm/openbox configs with:\n• Keybinds and basic layout\n• Status bar (polybar/lemonbar)\n• Rofi launcher\n• Simple colorscheme\n\nYou can customize further after installation." \
          14 70; then
          RICE_WM=1
        else
          RICE_WM=0
        fi
      else
        RICE_WM=0
      fi
      STEP=$((STEP + 1))
      ;;

    13) # Extra repos
      _repos=$(whiptail --title "$TITLE" --checklist \
        "Extra Repositories  [13/$STEP_MAX]" \
        14 72 4 \
        "multilib" "lib32 — Steam, Wine, 32-bit apps" OFF \
        "arch" "Arch [extra] — wider package selection" OFF \
        "galaxy" "Artix galaxy — community packages" OFF \
        "cachyos" "CachyOS — performance packages + kernels" OFF \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      _repos=$(echo "$_repos" | tr -d '"')
      echo "$_repos" | grep -qw multilib && MULTILIB=1 || MULTILIB=0
      echo "$_repos" | grep -qw arch && ENABLE_ARCH=1 || ENABLE_ARCH=0
      echo "$_repos" | grep -qw galaxy && ENABLE_GALAXY=1 || ENABLE_GALAXY=0
      echo "$_repos" | grep -qw cachyos && ENABLE_CACHYOS=1 || ENABLE_CACHYOS=0
      STEP=$((STEP + 1))
      ;;

    14) # Network
      _v=$(whiptail --title "$TITLE" --menu "Network Stack  [14/$STEP_MAX]" 13 65 3 \
        "dhcpcd" "dhcpcd  — ethernet only, ~2MB" \
        "iwd" "iwd     — wifi + ethernet, ~5MB" \
        "NM" "NetworkManager — full featured, ~30MB" \
        3>&1 1>&2 2>&3) || {
        STEP=$((STEP - 1))
        continue
      }
      NET_CHOICE="$_v"
      STEP=$((STEP + 1))
      ;;

    esac
    [ "$STEP" -gt "$STEP_MAX" ] && break
    [ "$STEP" -lt 1 ] && STEP=1
  done

fi # end TEST_MODE=0 Q&A

# =========================
# PRE-INSTALL SUMMARY
# =========================
if [ "$TEST_MODE" = "0" ]; then
  gauge 5 "Preparing installation..."

  _summary="INSTALLATION SUMMARY\n\n⚠️  WARNING: All data on $DISK will be erased!\n\n"
  _summary="$_summary━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  _summary="$_summary✓ Disk: $DISK\n"
  _summary="$_summary✓ Init: $INIT\n"
  _summary="$_summary✓ Filesystem: $FS\n"
  _summary="$_summary✓ Swap: $SWAP\n"
  _summary="$_summary✓ Encryption: $([ "$ENCRYPT" = "1" ] && echo "LUKS2" || echo "None")\n"
  _summary="$_summary✓ Bootloader: $BOOTLOADER\n"
  _summary="$_summary✓ Kernel: $FIRST_KERNEL\n"
  _summary="$_summary✓ DE/WM: $(echo "$DE_CHOICES" | tr '\n' ' ')\n"
  _summary="$_summary✓ Hostname: $HOSTNAME\n"
  _summary="$_summary✓ User: $USERNAME\n"
  _summary="$_summary━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\nReview the above. Continue?"

  if ! whiptail --title "$TITLE" --yesno "$_summary" 22 72; then
    echo ""
    echo "Installation cancelled by user at summary screen"
    exit 1
  fi
fi

# partition manager
if [ "$TEST_MODE" = "0" ]; then
  DISK_SIZE=$(lsblk -bdno SIZE "$DISK" 2>/dev/null || echo 0)
  DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
  EFI=""
  ROOT=""
  DUALBOOT=0
  [[ "$DISK" =~ (nvme|mmcblk) ]] && P="p" || P=""

  PART_MODE=$(whiptail --title "$TITLE" --menu \
    "Partitioning — $DISK (${DISK_SIZE_GB}GB)" 13 65 3 \
    "auto" "Auto — wipe disk, use entire drive (recommended)" \
    "manual" "Manual — open cfdisk to partition yourself" \
    "dualboot" "Dual-boot — keep existing partitions, pick root" \
    3>&1 1>&2 2>&3) || exit 1

  case "$PART_MODE" in
  auto)
    if [ "$UEFI" = "1" ]; then
      if [ "$SWAP" = "Partition" ]; then
        PART_DEVS=("${DISK}${P}1" "${DISK}${P}2" "${DISK}${P}3")
        PART_SIZES=("1" "$SWAP_SIZE_GB" "0")
        PART_TYPES=("EFI" "swap" "root")
        EFI="${DISK}${P}1"
        ROOT="${DISK}${P}3"
      else
        PART_DEVS=("${DISK}${P}1" "${DISK}${P}2")
        PART_SIZES=("1" "0")
        PART_TYPES=("EFI" "root")
        EFI="${DISK}${P}1"
        ROOT="${DISK}${P}2"
      fi
    else
      if [ "$SWAP" = "Partition" ]; then
        PART_DEVS=("${DISK}${P}1" "${DISK}${P}2")
        PART_SIZES=("$SWAP_SIZE_GB" "0")
        PART_TYPES=("swap" "root")
        ROOT="${DISK}${P}2"
      else
        PART_DEVS=("${DISK}${P}1")
        PART_SIZES=("0")
        PART_TYPES=("root")
        ROOT="${DISK}${P}1"
      fi
    fi
    ;;
  manual)
    whiptail --title "$TITLE" --msgbox \
      "cfdisk will open now.\n\nCreate your partitions and write the table.\nAfter exiting you select which partitions to use and their filesystems." \
      10 62
    cfdisk "$DISK"
    udevadm settle
    mapfile -t _parts < <(lsblk -pno NAME,SIZE,FSTYPE "$DISK" | grep -v "^$DISK " |
      awk '{print $1; printf "%s %s\n", $2, ($3=="" ? "unformatted" : $3)}')
    if [ "$UEFI" = "1" ]; then
      EFI=$(whiptail --title "$TITLE" --menu "Select EFI partition" \
        16 62 8 "${_parts[@]}" 3>&1 1>&2 2>&3) || exit 1
      _efi_fs=$(pick_fs "Filesystem for EFI partition" "vfat") || _efi_fs="vfat"
      PART_FS["$(fs_key "$EFI")"]="$_efi_fs"
    fi
    ROOT=$(whiptail --title "$TITLE" --menu "Select root partition" \
      16 62 8 "${_parts[@]}" 3>&1 1>&2 2>&3) || exit 1
    _root_fs=$(pick_fs "Filesystem for root partition" "$FS") || _root_fs="$FS"
    FS="$_root_fs"
    PART_FS["$(fs_key "$ROOT")"]="$_root_fs"
    # offer extra partitions (home, data, etc.)
    while true; do
      _remain_args=("skip" "Done — no more partitions")
      for _pp in "${_parts[@]}"; do
        [[ "$_pp" == /dev/* ]] && [ "$_pp" != "$EFI" ] && [ "$_pp" != "$ROOT" ] &&
          _remain_args+=("$_pp" "$(lsblk -dno SIZE "$_pp" 2>/dev/null)")
      done
      [ ${#_remain_args[@]} -le 2 ] && break
      _extra=$(whiptail --title "$TITLE" --menu \
        "Assign more partitions? (e.g. /home)" \
        16 62 8 "${_remain_args[@]}" 3>&1 1>&2 2>&3) || break
      [ "$_extra" = "skip" ] && break
      _extra_mp=$(whiptail --title "$TITLE" --inputbox \
        "Mount point for $_extra" 10 55 "/home" 3>&1 1>&2 2>&3) || break
      _extra_fs=$(pick_fs "Filesystem for $_extra ($_extra_mp)") || _extra_fs="ext4"
      PART_FS["$(fs_key "$_extra")"]="$_extra_fs"
      EXTRA_MOUNTS+=("$_extra:$_extra_mp")
    done
    PART_DEVS=()
    PART_SIZES=()
    PART_TYPES=()
    [ "$UEFI" = "1" ] && {
      PART_DEVS+=("$EFI")
      PART_SIZES+=("0")
      PART_TYPES+=("EFI")
    }
    PART_DEVS+=("$ROOT")
    PART_SIZES+=("0")
    PART_TYPES+=("root")
    ;;
  dualboot)
    DUALBOOT=1
    mapfile -t allparts < <(lsblk -pno NAME,SIZE,FSTYPE,PARTTYPE |
      grep -v '^/dev/[a-z]*[[:space:]]' |
      awk '{print $1; printf "%s %s %s\n", $2, ($3=="" ? "unformatted" : $3), ($4=="" ? "" : "[EFI]")}')
    EFI=$(whiptail --title "$TITLE" --menu \
      "Select your existing EFI partition (do NOT format it)" \
      18 72 10 "${allparts[@]}" 3>&1 1>&2 2>&3) || exit 1
    mapfile -t rootparts < <(lsblk -pno NAME,SIZE,FSTYPE "$DISK" |
      grep -v "^$DISK " |
      awk '{print $1; printf "%s %s\n", $2, ($3=="" ? "unformatted" : $3)}')
    ROOT=$(whiptail --title "$TITLE" --menu \
      "Select partition for Artix root (will be formatted as $FS)" \
      18 72 10 "${rootparts[@]}" 3>&1 1>&2 2>&3) || exit 1
    PART_DEVS=("$ROOT")
    PART_SIZES=("0")
    PART_TYPES=("root")
    ;;
  esac
fi # end TEST_MODE=0 partition manager

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
        EFI) TYPECODE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ;;
        swap) TYPECODE="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" ;;
        *) TYPECODE="0FC63DAF-8483-4772-8E79-3D69D8477DE4" ;;
        esac
        [ "$SZ" = "0" ] &&
          echo "size=+, type=$TYPECODE" ||
          echo "size=+${SZ}G, type=$TYPECODE"
      else
        case "$TYPE" in
        swap) TYPECODE="82" ;;
        *) TYPECODE="83" ;;
        esac
        BOOTFLAG=""
        [ "$TYPE" = "root" ] && BOOTFLAG=", bootable"
        [ "$SZ" = "0" ] &&
          echo "size=+, type=$TYPECODE$BOOTFLAG" ||
          echo "size=+${SZ}G, type=$TYPECODE$BOOTFLAG"
      fi
    done
  } | sfdisk "$DISK"
  # Give kernel time to re-read partition table — NVMe needs this
  partprobe "$DISK" 2>/dev/null || true
  udevadm settle --timeout=10
  sleep 1
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
  PART_FS["$(fs_key "$ROOT")"]="${PART_FS[$(fs_key "$REAL_ROOT")]:-$FS}"
fi

# format_part <device> <fstype>
format_part() {
  local _dev="$1" _fs="${2:-ext4}"
  case "$_fs" in
  ext4) mkfs.ext4 -F "$_dev" ;;
  btrfs) mkfs.btrfs -f "$_dev" ;;
  xfs) mkfs.xfs -f "$_dev" ;;
  f2fs) mkfs.f2fs -f "$_dev" ;;
  jfs) mkfs.jfs -q "$_dev" ;;
  nilfs2) mkfs.nilfs2 -f "$_dev" ;;
  vfat) mkfs.fat -F32 "$_dev" ;;
  exfat) mkfs.exfat "$_dev" ;;
  ntfs) mkfs.ntfs -f "$_dev" ;;
  zfs)
    # ZFS needs zfs-dkms on the live ISO
    if ! command -v zpool &>/dev/null; then
      pacman -Sy --noconfirm zfs-dkms zfs-utils 2>/dev/null ||
        pacman -Sy --noconfirm zfs-linux 2>/dev/null || true
      modprobe zfs 2>/dev/null || true
    fi
    # pool name: root pool = zroot, others use last path component
    local _pool="zroot"
    zpool create -f -o ashift=12 \
      -O acltype=posixacl -O xattr=sa \
      -O dnodesize=auto -O compression=lz4 \
      -O normalization=formD -O relatime=on \
      -O mountpoint=none \
      "$_pool" "$_dev"
    zfs create -o mountpoint=/ "${_pool}/root"
    # export/import so it mounts under /mnt
    zpool export "$_pool"
    zpool import -d /dev -R /mnt "$_pool"
    return
    ;;
  *)
    echo "==> Unknown FS '$_fs', defaulting to ext4"
    mkfs.ext4 -F "$_dev"
    ;;
  esac
}

# Format EFI (always vfat unless user picked something exotic)
[ "$UEFI" = "1" ] && [ -n "$EFI" ] && {
  _efi_fs="${PART_FS[$(fs_key "$EFI")]:-vfat}"
  format_part "$EFI" "$_efi_fs"
}

# Format root
_root_fs="${PART_FS[$(fs_key "$ROOT")]:-$FS}"
if [ "$_root_fs" = "zfs" ]; then
  format_part "$ROOT" "zfs"
  # ZFS import already mounted /mnt — skip normal mount below
  ZFS_ROOT=1
else
  ZFS_ROOT=0
  format_part "$ROOT" "$_root_fs"
  if [ "$_root_fs" = "btrfs" ]; then
    mount "$ROOT" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@cache
    [ "$BTRFS_SNAPSHOTS" = "1" ] && btrfs subvolume create /mnt/@snapshots
    umount /mnt
    mount -o subvol=@,compress=zstd,noatime "$ROOT" /mnt
    mkdir -p /mnt/{home,var}
    mount -o subvol=@home,compress=zstd,noatime "$ROOT" /mnt/home
    mount -o subvol=@var,compress=zstd,noatime "$ROOT" /mnt/var
    mkdir -p /mnt/var/cache
    mount -o subvol=@cache,compress=zstd,noatime,nodatacow "$ROOT" /mnt/var/cache
    if [ "$BTRFS_SNAPSHOTS" = "1" ]; then
      mkdir -p /mnt/.snapshots
      mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT" /mnt/.snapshots
    fi
  else
    mount "$ROOT" /mnt
  fi
fi

mkdir -p /mnt/boot
[ "$UEFI" = "1" ] && mount "$EFI" /mnt/boot

# Mount extra partitions (from manual mode)
for _em in "${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"}"; do
  [ -z "$_em" ] && continue
  _em_dev="${_em%%:*}"
  _em_mp="${_em##*:}"
  _em_fs="${PART_FS[$(fs_key "$_em_dev")]:-ext4}"
  [ "$_em_fs" != "zfs" ] && format_part "$_em_dev" "$_em_fs"
  mkdir -p "/mnt${_em_mp}"
  [ "$_em_fs" != "zfs" ] && mount "$_em_dev" "/mnt${_em_mp}"
done

# Activate swap partition now so fstabgen picks it up
[ -n "${SWAP_PART:-}" ] && swapon "$SWAP_PART"

# section headers during install
gauge() {
  echo ""
  echo "==> ${2}"
  echo ""
}

# svc_pkg <svc> — returns init-specific package name
svc_pkg() {
  case "$INIT" in
  dinit) echo "${1}-dinit" ;;
  openrc) echo "${1}-openrc" ;;
  runit) echo "${1}-runit" ;;
  s6) echo "${1}-s6" ;;
  esac
}

# svc_enable <svc> — enable service in installed system
# NOTE: for runit/s6/dinit, /run is a tmpfs not yet mounted in chroot,
# so we link into persistent dirs (runsvdir/default or adminsv/default/contents.d)
svc_enable() {
  local _s="$1"
  case "$INIT" in
  dinit)
    if [ -f "/mnt/etc/dinit.d/$_s" ]; then
      artix-chroot /mnt ln -sf "/etc/dinit.d/$_s" /etc/dinit.d/boot.d/
    else
      echo "Warning: dinit service $_s not found"
    fi
    ;;
  openrc)
    artix-chroot /mnt rc-update add "$_s" default 2>/dev/null ||
      echo "Warning: openrc service $_s not found"
    ;;
  runit)
    # Link into runsvdir/default — NOT /run/runit/service (tmpfs, not mounted in chroot)
    if [ -d "/mnt/etc/runit/sv/$_s" ]; then
      mkdir -p /mnt/etc/runit/runsvdir/default
      artix-chroot /mnt ln -sf "/etc/runit/sv/$_s" /etc/runit/runsvdir/default/
    else
      echo "Warning: runit service $_s not found in /etc/runit/sv/"
    fi
    ;;
  s6)
    # Add to default bundle contents.d; s6-db-reload compiles at end
    if [ -d "/mnt/etc/s6/sv/${_s}-srv" ] || [ -d "/mnt/etc/s6/adminsv/$_s" ]; then
      mkdir -p /mnt/etc/s6/adminsv/default/contents.d
      touch "/mnt/etc/s6/adminsv/default/contents.d/$_s"
    else
      echo "Note: s6 service $_s not found in sv/adminsv (may be in base bundle)"
    fi
    ;;
  esac
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
  swapon /mnt/swapfile # activate so fstabgen picks it up
fi

# icewm doesnt need mesa/llvm so skip gpu entirely to save ~200mb
BARE_WM_ONLY=1
for _de in Plasma XFCE LXQt Moksha Hyprland i3 XMonad Openbox Fluxbox; do
  echo "$DE_CHOICES" | grep -qw "$_de" && BARE_WM_ONLY=0 && break
done
[ "$DE_CHOICES" = "CLI" ] && BARE_WM_ONLY=0
[ "$BARE_WM_ONLY" = "1" ] && GPU=""

# XLibre is now in the main Artix [world] repo — no extra repo needed
XORG_PKGS=""
if [ "$DE_CHOICES" != "CLI" ] && ! echo "$DE_CHOICES" | grep -qw "Cosmic" && ! echo "$DE_CHOICES" | grep -qw "Hyprland"; then
  XORG_PKGS="xlibre-xserver xlibre-xserver-common xlibre-input-libinput xorg-xinit"
fi

# Only install audio stack for DEs that actually use it
AUDIO_PKGS=""
AUDIO_DES="Plasma XFCE LXQt Moksha Cosmic Hyprland"
for _de in $AUDIO_DES; do
  if echo "$DE_CHOICES" | grep -qw "$_de"; then
    # Select audio daemon based on user choice
    case "$AUDIO_DAEMON" in
    pipewire)
      AUDIO_PKGS="pipewire pipewire-pulse pipewire-alsa wireplumber"
      ;;
    pulseaudio)
      AUDIO_PKGS="pulseaudio pulseaudio-alsa"
      ;;
    alsa)
      # ALSA only — minimal, no daemon
      AUDIO_PKGS=""
      ;;
    esac
    break
  fi
done

# =========================
gauge 10 "Ranking mirrors for best speeds..."
# =========================
if command -v reflector &>/dev/null; then
  # Use reflector to rank mirrors — try common regions for fast downloads
  reflector --country US --country DE --country NL --country FR \
    --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || true
else
  echo "reflector not available, using default mirror list"
fi

# =========================
gauge 15 "Configuring repositories..."
# XLIBRE REPO (if needed)
# =========================
# =========================
# LIQUORIX REPO (if needed)
# =========================
if echo "$KERNEL_CHOICES" | grep -qw "linux-lqx"; then
  pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys 9AE4078033F8024D
  pacman-key --lsign-key 9AE4078033F8024D
  grep -q 'liquorix.net' /etc/pacman.conf ||
    printf '\n[liquorix]\nServer = https://liquorix.net/archlinux/$repo/$arch\n' >>/etc/pacman.conf
  pacman -Sy
fi

# cachyos repo — enabled by repo selection or linux-cachyos kernel
if [ "$ENABLE_CACHYOS" = "1" ] || echo "$KERNEL_CHOICES" | grep -qw "linux-cachyos"; then
  _cachy_ok=0
  set +e

  # Temporarily set global SigLevel = Never so pacman can install the keyring
  # package before we have CachyOS keys trusted. Per-repo SigLevel is unreliable
  # across pacman versions — global override is the only thing that always works.
  _orig_siglevel=$(grep '^SigLevel' /etc/pacman.conf | head -1)
  [ -z "$_orig_siglevel" ] && _orig_siglevel="SigLevel = Required DatabaseOptional"
  sed -i "s/^SigLevel.*/${_orig_siglevel}/" /etc/pacman.conf # ensure it exists first
  sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf

  # Add the repo (with a plain Server line, no per-repo SigLevel needed now)
  grep -q '\[cachyos\]' /etc/pacman.conf || printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n' >>/etc/pacman.conf

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
[ "$FS" = "btrfs" ] && EXTRA_PKGS="btrfs-progs $EXTRA_PKGS"
if [ "$BTRFS_SNAPSHOTS" = "1" ]; then
  _snapper_svc_pkg=$([ "$INIT" != "dinit" ] && svc_pkg snapper || true)
  EXTRA_PKGS="snapper snap-pac $_snapper_svc_pkg $EXTRA_PKGS"
fi

_do_basestrap() {
  local _k="$1"
  basestrap /mnt \
    base base-devel "$_k" linux-firmware $UCODE \
    $(case "$INIT" in dinit) echo "dinit elogind-dinit dbus-dinit" ;; openrc) echo "openrc elogind-openrc dbus-openrc" ;; runit) echo "runit elogind-runit dbus-runit" ;; s6) echo "s6-base elogind-s6 dbus-s6" ;; esac) \
    $([ "$NET_CHOICE" = "NM" ] && echo "networkmanager $(svc_pkg networkmanager)") \
    $([ "$PRIV_ESC" = "sudo" ] && echo "sudo" || echo "doas") $([ -n "$AUDIO_PKGS" ] && echo rtkit) \
    ttf-dejavu ttf-liberation noto-fonts \
    $XORG_PKGS \
    $AUDIO_PKGS \
    $GPU \
    $EXTRA_PKGS
}
if ! _do_basestrap "$FIRST_KERNEL"; then
  echo "==> $FIRST_KERNEL failed, falling back to linux"
  FIRST_KERNEL="linux"
  KERNEL_CHOICES="linux"
  _do_basestrap linux
fi

# XanMod can't be basestrapped (AUR only) — if it's the only/first kernel,
# basestrap used linux above; XanMod will be built in the extra kernels step
if echo "$KERNEL_CHOICES" | grep -qw "linux-xanmod"; then
  # ensure linux is in the mix as a fallback until xanmod is built
  echo "$KERNEL_CHOICES" | grep -qw "linux" || KERNEL_CHOICES="linux $KERNEL_CHOICES"
fi

gauge 35 "Writing fstab..."
if [ "${ZFS_ROOT:-0}" = "1" ]; then
  # ZFS root: generate fstab for non-ZFS mounts only, ZFS handles itself
  fstabgen -U /mnt | grep -v ' / ' >>/mnt/etc/fstab
  # install ZFS support in the target
  artix-chroot /mnt pacman -S --noconfirm zfs-dkms zfs-utils 2>/dev/null ||
    artix-chroot /mnt pacman -S --noconfirm zfs-linux 2>/dev/null || true
  # enable zfs service
  svc_enable zfs-import 2>/dev/null || true
  svc_enable zfs-mount 2>/dev/null || true
else
  fstabgen -U /mnt >>/mnt/etc/fstab
fi

# Encryption setup inside installed system
if [ "$ENCRYPT" = "1" ]; then
  # zstd mkinitcpio builds fail in some chroot environments — gzip is universal
  sed -i 's/^#*COMPRESSION=.*/COMPRESSION="gzip"/' /mnt/etc/mkinitcpio.conf
  grep -q '^COMPRESSION=' /mnt/etc/mkinitcpio.conf || echo 'COMPRESSION="gzip"' >>/mnt/etc/mkinitcpio.conf
  # Set HOOKS before installing cryptsetup so the pacman post-hook builds a
  # correct initramfs. consolefont is omitted — no font is configured at this
  # stage (vconsole.conf is written later) and mkinitcpio 41+ errors on it.
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf
  # Pin btrfs module so autodetect can't filter it out in a chroot environment
  [ "$FS" = "btrfs" ] &&
    sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /mnt/etc/mkinitcpio.conf
  # Ensure cryptsetup is in the installed system
  artix-chroot /mnt pacman -S --noconfirm cryptsetup
  # crypttab — maps cryptroot on boot
  LUKS_UUID=$(blkid -s UUID -o value "$REAL_ROOT")
  echo "cryptroot UUID=$LUKS_UUID none luks" >>/mnt/etc/crypttab
  artix-chroot /mnt mkinitcpio -P
  # Store LUKS UUID for bootloader cmdline
  LUKS_CMDLINE="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot"
fi

if [ "$BTRFS_SNAPSHOTS" = "1" ]; then
  umount /mnt/.snapshots 2>/dev/null || true
  rmdir /mnt/.snapshots 2>/dev/null || true
  artix-chroot /mnt snapper --no-dbus -c root create-config /
  mkdir -p /mnt/.snapshots
  mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT" /mnt/.snapshots
  sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' /mnt/etc/snapper/configs/root
  sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' /mnt/etc/snapper/configs/root
  sed -i 's/^SUBVOLUME=.*/SUBVOLUME="\/\.snapshots"/' /mnt/etc/snapper/configs/root 2>/dev/null || true
  sed -i 's/^EXCLUDE_PATTERNS=.*/EXCLUDE_PATTERNS=("\/\.snapshots" "\/var\/cache")/' /mnt/etc/snapper/configs/root 2>/dev/null || true
  svc_enable snapper-timeline
  svc_enable snapper-cleanup
fi

# pacman tweaks
sed -i 's/^#Color/Color\nILoveCandy/' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /mnt/etc/pacman.conf
# Enable selected extra repos in installed system
if [ "$ENABLE_ARCH" = "1" ] && ! grep -q '\[extra\]' /mnt/etc/pacman.conf; then
  artix-chroot /mnt pacman -S --noconfirm --needed artix-archlinux-support
  printf '
# Arch repos
[extra]
Include = /etc/pacman.d/mirrorlist-arch
' >>/mnt/etc/pacman.conf
  artix-chroot /mnt pacman-key --populate archlinux
fi

[ "$MULTILIB" = "1" ] && grep -q '\[lib32\]' /mnt/etc/pacman.conf || { [ "$MULTILIB" = "1" ] && printf '
[lib32]
Include = /etc/pacman.d/mirrorlist
' >>/mnt/etc/pacman.conf; }

[ "$ENABLE_GALAXY" = "1" ] && ! grep -q '\[galaxy\]' /mnt/etc/pacman.conf && printf '
[galaxy]
Include = /etc/pacman.d/mirrorlist
' >>/mnt/etc/pacman.conf

if [ "$MULTILIB" = "1" ] || [ "$ENABLE_ARCH" = "1" ] || [ "$ENABLE_GALAXY" = "1" ]; then
  artix-chroot /mnt pacman -Sy --noconfirm
fi

# Block legacy xf86-video DDX drivers — modesetting handles everything
# Prevents DE metapackages from pulling them in as optional deps
grep -q 'xf86-video-amdgpu' /mnt/etc/pacman.conf ||
  sed -i '/^\[options\]/a IgnorePkg = xf86-video-amdgpu xf86-video-intel xf86-video-nouveau xf86-video-fbdev xf86-video-vesa' \
    /mnt/etc/pacman.conf

# liquorix repo in the installed system
if echo "$KERNEL_CHOICES" | grep -qw "linux-lqx"; then
  artix-chroot /mnt pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys 9AE4078033F8024D
  artix-chroot /mnt pacman-key --lsign-key 9AE4078033F8024D
  grep -q 'liquorix.net' /mnt/etc/pacman.conf ||
    printf '\n[liquorix]\nServer = https://liquorix.net/archlinux/$repo/$arch\n' >>/mnt/etc/pacman.conf
  artix-chroot /mnt pacman -Sy --noconfirm
fi

# cachyos repo in the installed system
if [ "$ENABLE_CACHYOS" = "1" ] || echo "$KERNEL_CHOICES" | grep -qw "linux-cachyos"; then
  _orig_siglevel=$(grep '^SigLevel' /mnt/etc/pacman.conf | head -1)
  [ -z "$_orig_siglevel" ] && _orig_siglevel="SigLevel = Required DatabaseOptional"
  sed -i 's/^SigLevel.*/SigLevel = Never/' /mnt/etc/pacman.conf
  grep -q '\[cachyos\]' /mnt/etc/pacman.conf ||
    printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n' >>/mnt/etc/pacman.conf
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

# Extra kernels — skip silently if they fail
for K in $KERNEL_CHOICES; do
  [ "$K" = "$FIRST_KERNEL" ] && continue
  if [ "$K" = "linux-xanmod" ]; then
    echo "==> Building linux-xanmod from AUR — this will take a while..."
    artix-chroot /mnt bash -c "
            pacman -S --noconfirm --needed git base-devel
            git clone https://aur.archlinux.org/linux-xanmod.git /tmp/linux-xanmod
            chown -R ${USERNAME}:${USERNAME} /tmp/linux-xanmod
            cd /tmp/linux-xanmod
            # Use doas -u if available, otherwise sudo -u (will be wrapped by our sudo script)
            doas -u ${USERNAME} bash -c 'cd /tmp/linux-xanmod && MAKEFLAGS=\"-j\$(nproc)\" makepkg --noconfirm -s' || \
            sudo -u ${USERNAME} bash -c 'cd /tmp/linux-xanmod && MAKEFLAGS=\"-j\$(nproc)\" makepkg --noconfirm -s'
            pacman -U --noconfirm /tmp/linux-xanmod/linux-xanmod-*.pkg.tar.zst || true
            pacman -U --noconfirm /tmp/linux-xanmod/linux-xanmod-headers-*.pkg.tar.zst || true
            rm -rf /tmp/linux-xanmod
        " || echo "==> Warning: linux-xanmod build failed, skipping"
  elif [ "$K" = "linux-cachyos" ]; then
    artix-chroot /mnt pacman -S --noconfirm linux-cachyos || echo "==> Warning: linux-cachyos failed, skipping"
  elif [ "$K" = "linux-lqx" ]; then
    artix-chroot /mnt pacman -S --noconfirm linux-lqx linux-lqx-headers || echo "==> Warning: linux-lqx failed, skipping"
  else
    artix-chroot /mnt pacman -S --noconfirm "$K" "${K}-headers" || echo "==> Warning: $K failed, skipping"
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
us-intl) VC_KEYMAP="us" ;;
cz-qwerty) VC_KEYMAP="cz-qwerty" ;;
fr-bepo) VC_KEYMAP="fr-bepo" ;;
br-abnt2) VC_KEYMAP="br-abnt2" ;;
de-latin1) VC_KEYMAP="de-latin1" ;;
jp106) VC_KEYMAP="jp106" ;;
*) VC_KEYMAP="$KB_LAYOUT" ;;
esac
cat >/mnt/etc/vconsole.conf <<EOF
KEYMAP=$VC_KEYMAP
FONT=default
EOF
mkdir -p /mnt/etc/X11/xorg.conf.d
cat >/mnt/etc/X11/xorg.conf.d/00-keyboard.conf <<KBEOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KB_LAYOUT"
EndSection
KBEOF

# hostname
gauge 50 "Configuring hostname..."
echo "$HOSTNAME" >/mnt/etc/hostname
printf "127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost\n" "$HOSTNAME" >/mnt/etc/hosts

# Passwords — read directly from files inside chroot, no encoding needed
# Passwords — pass directly as env vars, no files, no subshells
ROOTPW_B64=$(printf '%s' "$ROOTPW" | base64)
USERPW_B64=$(printf '%s' "$USERPW" | base64)
# Set root password — pipe directly into chpasswd, never in bash -c where it's visible in ps aux
printf "root:%s\n" "$(printf '%s' "$ROOTPW_B64" | base64 -d)" | artix-chroot /mnt chpasswd
gauge 55 "Creating user account..."
artix-chroot /mnt bash -c "useradd -m -s '$USER_SHELL' -G wheel,audio,video,storage,input '$USERNAME'"
# Set user password — pipe directly into chpasswd, never in bash -c where it's visible in ps aux
printf "%s:%s\n" "$USERNAME" "$(printf '%s' "$USERPW_B64" | base64 -d)" | artix-chroot /mnt chpasswd
# Securely unset password variables from memory
unset ROOTPW USERPW ROOTPW_B64 USERPW_B64
USER_UID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f3)
USER_GID=$(grep "^${USERNAME}:" /mnt/etc/passwd | cut -d: -f4)

# privilege escalation config
if [ "$PRIV_ESC" = "sudo" ]; then
  _sudo_ok=0
  if [ -f /mnt/etc/sudoers ]; then
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /mnt/etc/sudoers
    grep -q '%wheel.*ALL' /mnt/etc/sudoers && _sudo_ok=1
  else
    mkdir -p /mnt/etc/sudoers.d
    echo "%wheel ALL=(ALL:ALL) ALL" >/mnt/etc/sudoers.d/wheel
    chmod 0440 /mnt/etc/sudoers.d/wheel
    _sudo_ok=1
  fi
  if [ "$_sudo_ok" = "0" ]; then
    echo "==> Warning: sudo config failed, falling back to doas"
    PRIV_ESC="doas"
  fi
fi
# doas — either as primary choice or fallback
if [ "$PRIV_ESC" = "doas" ]; then
  # ensure doas is installed (may have been skipped if sudo was chosen initially)
  [ ! -f /mnt/usr/bin/doas ] && artix-chroot /mnt pacman -S --noconfirm doas 2>/dev/null || true
  cat >/mnt/etc/doas.conf <<'EOF'
# keepenv preserves env vars — required for yay/paru (MAKEFLAGS, BUILDDIR, etc.)
permit keepenv persist :wheel
permit keepenv nopass :wheel cmd pacman
permit keepenv nopass :wheel cmd makepkg
EOF
  chmod 0400 /mnt/etc/doas.conf
  # Install both doas and sudo for maximum compatibility
  # doas is preferred, but some AUR tools expect sudo
  artix-chroot /mnt pacman -S --noconfirm sudo
  # Configure sudoers for wheel group with NOPASSWD for pacman (optional, keeps it consistent with doas)
  mkdir -p /mnt/etc/sudoers.d
  printf '%%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman\n' >/mnt/etc/sudoers.d/pacman
  chmod 440 /mnt/etc/sudoers.d/pacman
fi

# Apply WM riced dotfiles if requested
if [ "$RICE_WM" = "1" ]; then
  echo "==> Setting up riced WM dotfiles..."
  # Create minimal config directories
  mkdir -p /mnt/home/"$USERNAME"/.config/{i3,openbox,bspwm,rofi,polybar}

  # Detect which WM was chosen and apply appropriate config
  if echo "$DE_CHOICES" | grep -qw "i3"; then
    # Basic i3 config
    cat >/mnt/home/"$USERNAME"/.config/i3/config <<'I3CONFIG'
set $mod Mod1
set $term xterm
set $menu rofi -show run -display-run "❯ " -display-window "⊟ "

# Use Font for window titles
font pango:monospace 8

# Use Mouse+$mod to drag floating windows
floating_modifier $mod

# Start a terminal
bindsym $mod+Return exec $term

# Kill focused window
bindsym $mod+Shift+q kill

# Start launcher
bindsym $mod+d exec $menu

# Change focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Move window
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Split
bindsym $mod+z split h
bindsym $mod+v split v

# Layout
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split

# Fullscreen
bindsym $mod+f fullscreen

# Floating
bindsym $mod+space floating toggle
bindsym $mod+shift+space focus mode_toggle

# Workspaces
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+6 workspace number 6
bindsym $mod+7 workspace number 7
bindsym $mod+8 workspace number 8
bindsym $mod+9 workspace number 9
bindsym $mod+0 workspace number 10

bindsym $mod+shift+1 move container to workspace number 1
bindsym $mod+shift+2 move container to workspace number 2
bindsym $mod+shift+3 move container to workspace number 3
bindsym $mod+shift+4 move container to workspace number 4
bindsym $mod+shift+5 move container to workspace number 5
bindsym $mod+shift+6 move container to workspace number 6
bindsym $mod+shift+7 move container to workspace number 7
bindsym $mod+shift+8 move container to workspace number 8
bindsym $mod+shift+9 move container to workspace number 9
bindsym $mod+shift+0 move container to workspace number 10

# Reload/restart
bindsym $mod+shift+c reload
bindsym $mod+shift+r restart

# Exit
bindsym $mod+shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -b 'Yes' 'i3-msg exit'"

# Resize
mode "resize" {
    bindsym h resize shrink width 10 px or 10 ppt
    bindsym k resize grow height 10 px or 10 ppt
    bindsym j resize shrink height 10 px or 10 ppt
    bindsym l resize grow width 10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# Theme
client.focused          #4c7899 #285577 #ffffff #2e9ef4   #285577
client.focused_inactive #333333 #5f676e #ffffff #484e50   #5f676e
client.unfocused        #333333 #222222 #888888 #292d2e   #222222
client.urgent           #2f343a #900000 #ffffff #900000   #900000
client.placeholder      #000000 #0c0c0c #ffffff #000000   #0c0c0c

# Status bar
bar {
    status_command i3status
    position top
}
I3CONFIG
    chown "$USER_UID:$USER_GID" /mnt/home/"$USERNAME"/.config/i3/config
  elif echo "$DE_CHOICES" | grep -qw "Openbox"; then
    # Basic openbox notes
    cat >/mnt/home/"$USERNAME"/.config/openbox/README.txt <<'OBREADME'
Openbox Configuration
=====================
Edit the following files in ~/.config/openbox/:
- rc.xml: Keybinds, mouse button actions, themes
- autostart: Startup programs

Start your status bar/panel here or in .xinitrc

Example: picom (compositor), tint2 (panel), rofi (menu)
OBREADME
    chown "$USER_UID:$USER_GID" /mnt/home/"$USERNAME"/.config/openbox/README.txt
  elif echo "$DE_CHOICES" | grep -qw "Fluxbox"; then
    # Basic fluxbox notes
    cat >/mnt/home/"$USERNAME"/.fluxbox/README.txt <<'FBREADME'
Fluxbox Configuration
=====================
Main config files in ~/.fluxbox/:
- init: Main configuration
- keys: Keybinds
- menu: Right-click menu

See /usr/share/fluxbox/ for examples and themes
FBREADME
    chown "$USER_UID:$USER_GID" /mnt/home/"$USERNAME"/.fluxbox/README.txt
  fi

  echo "==> WM dotfiles applied. Customize in ~/.config/ or ~/.fluxbox/ after login."
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
if [ "$NEED_AUDIO" = "1" ] && [ "$AUDIO_DAEMON" = "pipewire" ]; then

  cat >/mnt/usr/local/bin/start-pipewire <<'EOF'
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
  cat >/mnt/home/"$USERNAME"/.config/autostart/pipewire.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=/usr/local/bin/start-pipewire
X-KDE-autostart-phase=1
EOF

  fi# Note: autostart-scripts/ intentionally omitted — KDE auto-converts scripts
  # in that directory into broken .desktop files pointing to wrong paths

  if echo "$DE_CHOICES" | grep -qw "Moksha"; then
    mkdir -p /mnt/home/"$USERNAME"/.e/e/applications/startup
    cat >/mnt/home/"$USERNAME"/.e/e/applications/startup/pipewire.desktop <<'EOF'
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

# Write .desktop session files for bare WMs so DMs (lightdm, sddm) can launch them
for _wm in $BARE_WMS; do
  if echo "$DE_CHOICES" | grep -qw "$_wm"; then
    mkdir -p /mnt/usr/share/xsessions
    case "$_wm" in
    i3) _wm_exec="i3" ;;
    XMonad) _wm_exec="xmonad" ;;
    Openbox) _wm_exec="openbox-session" ;;
    Fluxbox) _wm_exec="startfluxbox" ;;
    IceWM) _wm_exec="icewm-session" ;;
    esac
    cat >"/mnt/usr/share/xsessions/${_wm}.desktop" <<EOF
[Desktop Entry]
Name=$_wm
Exec=$_wm_exec
Type=Application
EOF
  fi
done

# Only set up autologin + startx if no DM is being installed
# If a DM is present it owns the session — startx in .bash_profile would conflict
_has_bare_wm=0
for _wm in $BARE_WMS; do
  echo "$DE_CHOICES" | grep -qw "$_wm" && _has_bare_wm=1 && break
done

if [ "$_has_bare_wm" = "1" ] && [ -z "$DM" ]; then
  # pure bare WM setup — autologin on tty1 and startx
  cat >>/mnt/home/"$USERNAME"/.bash_profile <<'EOF'
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx
EOF
  chown "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.bash_profile
  case "$INIT" in
  dinit)
    cat >/mnt/etc/dinit.d/agetty-tty1 <<EOF
type = process
command = /sbin/agetty --autologin $USERNAME --noclear tty1 38400 linux
restart = true
depends-on = elogind
EOF
    ;;
  openrc)
    mkdir -p /mnt/etc/conf.d
    cat >/mnt/etc/conf.d/agetty.tty1 <<EOF
agetty_options="--autologin $USERNAME --noclear"
EOF
    for pam_file in login system-auth; do
      PAM_PATH="/mnt/etc/pam.d/$pam_file"
      [ -f "$PAM_PATH" ] || continue
      sed -i 's/pam_unix.so$/pam_unix.so nullok/' "$PAM_PATH" 2>/dev/null || true
      grep -q 'pam_elogind.so' "$PAM_PATH" ||
        echo 'session optional pam_elogind.so' >>"$PAM_PATH"
    done
    ;;
  runit)
    mkdir -p /mnt/etc/runit/sv/agetty-tty1
    printf '#!/bin/sh\nexec agetty --autologin %s --noclear tty1 linux\n' "$USERNAME" \
      >/mnt/etc/runit/sv/agetty-tty1/run
    chmod +x /mnt/etc/runit/sv/agetty-tty1/run
    artix-chroot /mnt ln -sf /etc/runit/sv/agetty-tty1 /etc/runit/runsvdir/default/ 2>/dev/null || true
    ;;
  s6)
    # s6: create a custom longrun service for autologin getty
    mkdir -p /mnt/etc/s6/adminsv/agetty-tty1
    printf 'longrun\n' >/mnt/etc/s6/adminsv/agetty-tty1/type
    printf '#!/bin/execlineb -P\nagetty --autologin %s --noclear tty1 linux\n' "$USERNAME" \
      >/mnt/etc/s6/adminsv/agetty-tty1/run
    chmod +x /mnt/etc/s6/adminsv/agetty-tty1/run
    mkdir -p /mnt/etc/s6/adminsv/default/contents.d
    touch /mnt/etc/s6/adminsv/default/contents.d/agetty-tty1
    ;;
  esac
elif [ "$_has_bare_wm" = "1" ] && [ -n "$DM" ]; then
  # mixed: bare WMs + a DM — DM handles login, session files written above
  echo "==> Bare WMs registered as DM sessions — select them from $DM login screen"
fi

gauge 60 "Configuring swap..."
# zram swap
if [[ "$SWAP" =~ Zram|Both ]]; then
  ZRAM_MB=$((RAM_KB / 1024 / 2))
  ((ZRAM_MB > 8192)) && ZRAM_MB=8192

  cat >/mnt/usr/local/bin/zram-setup <<EOF
#!/bin/bash
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || echo lzo > /sys/block/zram0/comp_algorithm
echo ${ZRAM_MB}M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
EOF
  chmod +x /mnt/usr/local/bin/zram-setup

  cat >/mnt/usr/local/bin/zram-teardown <<'EOF'
#!/bin/bash
swapoff /dev/zram0 2>/dev/null
echo 1 > /sys/block/zram0/reset
modprobe -r zram
EOF
  chmod +x /mnt/usr/local/bin/zram-teardown

  case "$INIT" in
  dinit)
    cat >/mnt/etc/dinit.d/zram <<'EOF'
type = scripted
command = /usr/local/bin/zram-setup
stop-command = /usr/local/bin/zram-teardown
EOF
    ;;
  openrc)
    cat >/mnt/etc/init.d/zram <<'EOF'
#!/sbin/openrc-run
description="zram swap"
command="/usr/local/bin/zram-setup"
stop() { /usr/local/bin/zram-teardown; }
EOF
    chmod +x /mnt/etc/init.d/zram
    ;;
  runit)
    mkdir -p /mnt/etc/runit/sv/zram
    printf '#!/bin/sh\nexec /usr/local/bin/zram-setup\n' >/mnt/etc/runit/sv/zram/run
    printf '#!/bin/sh\nexec /usr/local/bin/zram-teardown\n' >/mnt/etc/runit/sv/zram/finish
    chmod +x /mnt/etc/runit/sv/zram/run /mnt/etc/runit/sv/zram/finish
    ;;
  s6)
    mkdir -p /mnt/etc/s6/adminsv/zram
    printf 'longrun\n' >/mnt/etc/s6/adminsv/zram/type
    printf '#!/bin/execlineb -P\n/usr/local/bin/zram-setup\n' >/mnt/etc/s6/adminsv/zram/run
    chmod +x /mnt/etc/s6/adminsv/zram/run
    ;;
  esac
fi

gauge 65 "Installing desktop environment..."
# DM priority: Cosmic/Hyprland need greetd, Plasma needs sddm, rest use lightdm
# greetd > sddm > lightdm — heavier DMs override lighter ones
if echo "$DE_CHOICES" | grep -qwE "Cosmic|Hyprland"; then
  DM="greetd"
elif echo "$DE_CHOICES" | grep -qw "Plasma"; then
  DM="sddm"
elif echo "$DE_CHOICES" | grep -qwE "XFCE|LXQt|Moksha"; then
  DM="lightdm"
else
  DM=""
fi

_failed_des=""
for DE in $DE_CHOICES; do
  _de_ok=1
  case "$DE" in
  Plasma)
    artix-chroot /mnt pacman -S --noconfirm \
      plasma-desktop kwin plasma-pa plasma-nm \
      powerdevil kscreen kde-gtk-config \
      breeze breeze-gtk knotifications \
      polkit-kde-agent xdg-desktop-portal-kde \
      dolphin konsole spectacle ark gwenview \
      plasma-systemmonitor ksystemstats bluedevil || _de_ok=0
    ;;
  XFCE)
    artix-chroot /mnt pacman -S --noconfirm \
      xfce4 xfce4-goodies xdg-desktop-portal-gtk \
      pavucontrol thunar-archive-plugin || _de_ok=0
    ;;
  LXQt)
    artix-chroot /mnt pacman -S --noconfirm lxqt || _de_ok=0
    ;;
  i3)
    artix-chroot /mnt pacman -S --noconfirm i3-wm dmenu xterm || _de_ok=0
    ;;
  XMonad)
    artix-chroot /mnt pacman -S --noconfirm artix-archlinux-support
    if ! grep -q '\[extra\]' /mnt/etc/pacman.conf; then
      printf '\n# Arch repos\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >>/mnt/etc/pacman.conf
      artix-chroot /mnt pacman-key --populate archlinux
    fi
    artix-chroot /mnt pacman -Sy --noconfirm
    artix-chroot /mnt pacman -S --noconfirm xmonad xmonad-contrib xterm dmenu git || { _de_ok=0; }
    [ "$_de_ok" = "1" ] && artix-chroot /mnt bash -c "
                mkdir -p /home/$USERNAME/.config
                git clone https://github.com/feribsd/xmonad-dotfiles.git /tmp/xmonad-dotfiles
                cp -r /tmp/xmonad-dotfiles/. /home/$USERNAME/.config/
                rm -rf /tmp/xmonad-dotfiles
                chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/
            "
    ;;
  Openbox)
    artix-chroot /mnt pacman -S --noconfirm openbox xterm dmenu || _de_ok=0
    ;;
  Fluxbox)
    artix-chroot /mnt pacman -S --noconfirm fluxbox xterm dmenu || _de_ok=0
    ;;
  IceWM)
    artix-chroot /mnt pacman -S --noconfirm icewm xterm || _de_ok=0
    mkdir -p /mnt/home/"$USERNAME"/.config/icewm
    ;;
  Hyprland)
    artix-chroot /mnt pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland || { _de_ok=0; }
    if [ "$_de_ok" = "1" ]; then
      mkdir -p /mnt/home/"$USERNAME"/.config/hypr
      cat >>/mnt/home/"$USERNAME"/.config/hypr/hyprland.conf <<'HYPREOF'
$([ "$AUDIO_DAEMON" = "pipewire" ] && echo "exec-once = /usr/local/bin/start-pipewire")
HYPREOF
      chown -R "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.config/hypr
      mkdir -p /mnt/usr/share/wayland-sessions
      cat >/mnt/usr/share/wayland-sessions/hyprland.desktop <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=A dynamic tiling Wayland compositor
Exec=Hyprland
Type=Application
EOF
    fi
    ;;
  Moksha)
    artix-chroot /mnt pacman -S --noconfirm moksha-artix || _de_ok=0
    ;;
  GNOME)
    # GNOME is unmaintained in Artix (upstream requires systemd)
    echo "==> Installing GNOME (unmaintained, no security updates)..."
    artix-chroot /mnt pacman -S --noconfirm gnome gnome-extra || _de_ok=0
    ;;
  bspwm)
    artix-chroot /mnt pacman -S --noconfirm bspwm sxhkd xterm dmenu rofi polybar || _de_ok=0
    mkdir -p /mnt/home/"$USERNAME"/.config/{bspwm,sxhkd,polybar}
    ;;
  Sway)
    # Sway is i3-like on Wayland
    artix-chroot /mnt pacman -S --noconfirm sway waybar swaybg xdg-desktop-portal-wlr bemenu || _de_ok=0
    mkdir -p /mnt/home/"$USERNAME"/.config/sway
    ;;
  dwm)
    # dwm requires manual building and patching — complex for installer
    echo "==> Note: dwm requires source patching and manual build"
    echo "    Install base packages; build after installation"
    artix-chroot /mnt pacman -S --noconfirm base-devel git || _de_ok=0
    ;;
  esac
  [ "$_de_ok" = "0" ] && _failed_des="$_failed_des $DE"
done

[ -n "$_failed_des" ] && echo "==> Warning: failed to install:$_failed_des — install manually after boot"

# write .xinitrc for bare WMs — done after loop so all WMs are installed
BARE_WMS_SELECTED=""
for _wm in i3 XMonad Openbox Fluxbox IceWM; do
  echo "$DE_CHOICES" | grep -qw "$_wm" && BARE_WMS_SELECTED="$BARE_WMS_SELECTED $_wm"
done
BARE_WMS_SELECTED="${BARE_WMS_SELECTED# }"

if [ -n "$BARE_WMS_SELECTED" ]; then
  wm_exec() {
    case "$1" in
    i3) echo "exec i3" ;;
    XMonad) echo "exec xmonad" ;;
    Openbox) echo "exec openbox-session" ;;
    Fluxbox) echo "exec startfluxbox" ;;
    IceWM) echo "exec icewm-session" ;;
    esac
  }
  WM_COUNT=$(echo "$BARE_WMS_SELECTED" | wc -w)
  {
    cat <<'XINITRC_HEADER'
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
      # generate a whiptail picker that runs at login
      printf 'WMLIST=('
      for _wm in $BARE_WMS_SELECTED; do printf '"%s" "" ' "$_wm"; done
      printf ')\n'
      cat <<'WMPICKER'
_wm_choice=$(whiptail --title "Window Manager" --menu "Select WM to launch:" 15 50 8 "${WMLIST[@]}" 3>&1 1>&2 2>&3)
[ -z "$_wm_choice" ] && _wm_choice="${WMLIST[0]}"
WMPICKER
      for _wm in $BARE_WMS_SELECTED; do
        echo "[ \"\$_wm_choice\" = \"$_wm\" ] && $(wm_exec $_wm)"
      done
      wm_exec "$(echo "$BARE_WMS_SELECTED" | awk '{print $1}')"
    fi
  } >/mnt/home/"$USERNAME"/.xinitrc
  chmod +x /mnt/home/"$USERNAME"/.xinitrc
  chown "${USER_UID}:${USER_GID}" /mnt/home/"$USERNAME"/.xinitrc
fi

if [ -n "$DM" ]; then
  if [[ "$DM" == "greetd" ]]; then
    artix-chroot /mnt pacman -S --noconfirm greetd "$(svc_pkg greetd)"
    mkdir -p /mnt/etc/greetd
    if echo "$DE_CHOICES" | grep -qw "Cosmic"; then
      # Cosmic owns greetd — its own greeter handles session selection
      cat >/mnt/etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "cosmic-comp cosmic-greeter"
user = "cosmic-greeter"
EOF
    else
      # Hyprland only (or Hyprland + bare WMs — land in Hyprland by default)
      cat >/mnt/etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "Hyprland"
user = "$USERNAME"
EOF
    fi
  elif [[ "$DM" == "sddm" ]]; then
    artix-chroot /mnt pacman -S --noconfirm sddm "$(svc_pkg sddm)"
    # sddm picks up all installed .desktop session files automatically
  elif [[ "$DM" == "lightdm" ]]; then
    artix-chroot /mnt pacman -S --noconfirm lightdm lightdm-gtk-greeter "$(svc_pkg lightdm)"
    # lightdm picks up all installed .desktop session files automatically
  fi
fi

gauge 85 "Enabling services..."
# enable services

# CPU governor
cat >/mnt/etc/cpupower.conf <<'EOF'
governor='schedutil'
EOF

# Install chosen network stack + migrate NM wifi profiles if needed
case "$NET_CHOICE" in
dhcpcd)
  artix-chroot /mnt pacman -S --noconfirm dhcpcd "$(svc_pkg dhcpcd)"
  NET_SVC="dhcpcd"
  ;;
iwd)
  artix-chroot /mnt pacman -S --noconfirm iwd "$(svc_pkg iwd)"
  NET_SVC="iwd"
  if [ -d /etc/NetworkManager/system-connections ]; then
    mkdir -p /mnt/var/lib/iwd
    for nmconf in /etc/NetworkManager/system-connections/*.nmconnection; do
      [ -f "$nmconf" ] || continue
      SSID=$(awk -F= '/^ssid=/{print $2}' "$nmconf")
      PSK=$(awk -F= '/^psk=/{print $2}' "$nmconf")
      [ -z "$SSID" ] && continue
      IWDFILE="/mnt/var/lib/iwd/${SSID}.psk"
      [ -n "$PSK" ] && printf '[Security]\nPassphrase=%s\n' "$PSK" >"$IWDFILE" ||
        printf '[Security]\n' >"$IWDFILE"
      chmod 600 "$IWDFILE"
      echo "Migrated wifi: $SSID"
    done
  fi
  ;;
NM)
  NET_SVC="NetworkManager"
  ;;
esac

artix-chroot /mnt pacman -S --noconfirm cpupower "$(svc_pkg cpupower)"

SVCS="dbus $NET_SVC elogind cpupower"
echo "$DE_CHOICES" | grep -qw "Cosmic" && SVCS="$SVCS upower"
[ -n "$DM" ] && SVCS="$SVCS $DM"

case "$INIT" in
dinit)
  mkdir -p /mnt/etc/dinit.d/boot.d
  [ -f /mnt/etc/dinit.d/rtkit-daemon ] && SVCS="$SVCS rtkit-daemon" || { [ -f /mnt/etc/dinit.d/rtkit ] && SVCS="$SVCS rtkit"; }
  echo "$DE_CHOICES" | grep -qw "Cosmic" && SVCS="$SVCS turnstiled"
  for svc in $SVCS; do svc_enable "$svc"; done
  [[ "$SWAP" =~ Zram|Both ]] && svc_enable zram || true
  for tty in 2 3 4 5 6; do
    rm -f /mnt/etc/dinit.d/boot.d/getty@tty${tty} 2>/dev/null || true
    artix-chroot /mnt dinitctl disable getty@tty${tty} 2>/dev/null || true
  done
  ;;
openrc)
  [ -f /mnt/etc/init.d/rtkit ] && SVCS="$SVCS rtkit"
  for svc in $SVCS; do svc_enable "$svc"; done
  [[ "$SWAP" =~ Zram|Both ]] && artix-chroot /mnt rc-update add zram boot 2>/dev/null || true
  for tty in 2 3 4 5 6; do
    artix-chroot /mnt rc-update del agetty.tty${tty} 2>/dev/null || true
  done
  ;;
runit)
  mkdir -p /mnt/etc/runit/runsvdir/default
  [ -f /mnt/etc/runit/sv/rtkit/run ] && SVCS="$SVCS rtkit"
  for svc in $SVCS; do svc_enable "$svc"; done
  [[ "$SWAP" =~ Zram|Both ]] && svc_enable zram || true
  ;;
s6)
  [ -d /mnt/etc/s6/sv/rtkit-srv ] && SVCS="$SVCS rtkit"
  for svc in $SVCS; do svc_enable "$svc"; done
  [[ "$SWAP" =~ Zram|Both ]] && svc_enable zram || true
  # Compile the s6-rc database so services are active on next boot
  artix-chroot /mnt s6-db-reload 2>/dev/null || artix-chroot /mnt s6-rc-db-update 2>/dev/null || true
  ;;
esac

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
    grep -q 'GRUB_DISABLE_OS_PROBER' /mnt/etc/default/grub ||
      echo 'GRUB_DISABLE_OS_PROBER=false' >>/mnt/etc/default/grub
    # Mount other partitions so os-prober can find them
    mount --bind /dev /mnt/dev
    mount --bind /proc /mnt/proc
    mount --bind /sys /mnt/sys
  fi
  if [ "$UEFI" = "1" ]; then
    artix-chroot /mnt grub-install \
      --target=x86_64-efi \
      --efi-directory=/boot \
      --bootloader-id=Artix \
      --recheck

    # Also install to the fallback path /EFI/BOOT/BOOTX64.EFI
    # Many boards (especially cheaper/older ones) ignore NVRAM entries
    # and only boot from this hardcoded fallback location
    mkdir -p /mnt/boot/EFI/BOOT
    cp /mnt/boot/EFI/Artix/grubx64.efi /mnt/boot/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true

    # Register an explicit NVRAM boot entry — grub-install does this but
    # some firmware clears it on reboot; efibootmgr makes it stick
    EFI_PART_NUM=$(echo "$EFI" | grep -o '[0-9]*$')
    efibootmgr --create \
      --disk "$DISK" \
      --part "$EFI_PART_NUM" \
      --label "Artix Linux" \
      --loader '\EFI\Artix\grubx64.efi' 2>/dev/null || true
  else
    artix-chroot /mnt grub-install --target=i386-pc --recheck "$DISK"
  fi
  if [ "$ENCRYPT" = "1" ]; then
    GRUB_LUKS="cryptdevice=UUID=$(blkid -s UUID -o value "$REAL_ROOT"):cryptroot root=/dev/mapper/cryptroot"
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_LUKS\"|" /mnt/etc/default/grub
    sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /mnt/etc/default/grub
  fi
  if [ "$FS" = "btrfs" ]; then
    grep -q 'GRUB_PRELOAD_MODULES' /mnt/etc/default/grub &&
      sed -i 's/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES="btrfs"/' /mnt/etc/default/grub ||
      echo 'GRUB_PRELOAD_MODULES="btrfs"' >>/mnt/etc/default/grub
    if [ "$ENCRYPT" = "1" ]; then
      GRUB_LUKS="$GRUB_LUKS rootflags=subvol=@"
      sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_LUKS\"|" /mnt/etc/default/grub
    else
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 rootflags=subvol=@"/' /mnt/etc/default/grub
    fi
    if [ "$BTRFS_SNAPSHOTS" = "1" ]; then
      artix-chroot /mnt pacman -S --noconfirm grub-btrfs
      svc_enable grub-btrfsd
    fi
  fi
  artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  # Unmount bind mounts used by os-prober
  [ "$DUALBOOT" = "1" ] && { umount /mnt/sys /mnt/proc /mnt/dev 2>/dev/null || true; }
  ;;
limine)
  artix-chroot /mnt pacman -S --noconfirm limine efibootmgr limine-mkinitcpio-hook limine-snapper-sync

  # Get the EFI partition number from its device path
  EFI_PART_NUM=$(echo "$EFI" | grep -o '[0-9]*$')

  # Install Limine EFI binary
  mkdir -p /mnt/boot/EFI/limine
  # Limine ships the EFI binary at this path
  cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/limine/ 2>/dev/null ||
    cp /mnt/usr/share/limine/limine-uefi.efi /mnt/boot/EFI/limine/BOOTX64.EFI 2>/dev/null || true

  efibootmgr --create \
    --disk "$DISK" \
    --part "$EFI_PART_NUM" \
    --label "Limine" \
    --loader '\EFI\limine\BOOTX64.EFI' 2>/dev/null || true

  # Fallback path — boards that ignore NVRAM entries boot from here
  mkdir -p /mnt/boot/EFI/BOOT
  cp /mnt/boot/EFI/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true

  if [ "$ENCRYPT" = "1" ]; then
    PART_UUID=$(blkid -s UUID -o value "$REAL_ROOT")
    LIMINE_CMDLINE="cryptdevice=UUID=$PART_UUID:cryptroot root=/dev/mapper/cryptroot rw quiet"
  else
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
    LIMINE_CMDLINE="root=UUID=$ROOT_UUID rw quiet"
  fi
  [ "$FS" = "btrfs" ] && LIMINE_CMDLINE="$LIMINE_CMDLINE rootflags=subvol=@"

  # Limine config — key names from official CONFIG.md
  # protocol, path, cmdline, module_path (NOT kernel_path/kernel_cmdline)
  cat >/mnt/boot/limine.conf <<EOF
timeout: 5
verbose: no

/Artix Linux
    protocol: linux
    path: boot():/vmlinuz-$FIRST_KERNEL
    cmdline: $LIMINE_CMDLINE
    module_path: boot():/${UCODE}.img
    module_path: boot():/initramfs-$FIRST_KERNEL.img
EOF

  if [ "$BTRFS_SNAPSHOTS" = "1" ]; then
    cat >/mnt/usr/local/bin/limine-snapshot-update <<'LSCRIPT'
#!/bin/bash
CONF=/boot/limine.conf
sed -i '/^\/Artix Linux (Snapshot/,/^$/d' "$CONF"
find /.snapshots -maxdepth 2 -name info.xml 2>/dev/null | sort -rV | head -10 | while read -r xml; do
    num=$(basename "$(dirname "$xml")")
    date=$(grep -oP '(?<=<date>)[^<]+' "$xml" | head -1)
    desc=$(grep -oP '(?<=<description>)[^<]+' "$xml" | head -1)
    label="${date:-snapshot} ${desc:+(${desc})}"
    cmdline=$(grep -oP '(?<=cmdline: ).*' "$CONF" | head -1 | sed "s|subvol=@[^ ]*|subvol=@snapshots/$num/snapshot|")
    printf '\n/Artix Linux (Snapshot %s — %s)\n' "$num" "$label"
    printf '    protocol: linux\n'
    printf '    path: boot():/vmlinuz-linux\n'
    printf '    cmdline: %s\n' "$cmdline"
    printf '    module_path: boot():/initramfs-linux.img\n'
done >> "$CONF"
LSCRIPT
    chmod +x /mnt/usr/local/bin/limine-snapshot-update

    mkdir -p /mnt/etc/snapper/hooks/post
    cat >/mnt/etc/snapper/hooks/post/limine-snapshot-update <<'HOOK'
#!/bin/bash
/usr/local/bin/limine-snapshot-update
HOOK
    chmod +x /mnt/etc/snapper/hooks/post/limine-snapshot-update
  fi
  ;;
refind)
  artix-chroot /mnt pacman -S --noconfirm refind efibootmgr
  artix-chroot /mnt refind-install
  # Explicit NVRAM entry — refind-install does this but reinforcing helps on picky firmware
  EFI_PART_NUM=$(echo "$EFI" | grep -o '[0-9]*$')
  efibootmgr --create \
    --disk "$DISK" \
    --part "$EFI_PART_NUM" \
    --label "rEFInd" \
    --loader '\\EFI\\refind\\refind_x64.efi' 2>/dev/null || true
  ROOT_UUID=$(blkid -s UUID -o value "${REAL_ROOT:-$ROOT}")
  # Build initrd line with microcode first, then initramfs
  _INITRD="initrd=/${UCODE}.img initrd=/initramfs-$FIRST_KERNEL.img"
  _btrfs_flag=""
  [ "$FS" = "btrfs" ] && _btrfs_flag=" rootflags=subvol=@"

  if [ "$ENCRYPT" = "1" ]; then
    printf '"Boot with standard options"  "%s root=/dev/mapper/cryptroot rw quiet%s %s"\n' \
      "$LUKS_CMDLINE" "$_btrfs_flag" "$_INITRD" >/mnt/boot/refind_linux.conf
  else
    printf '"Boot with standard options"  "root=UUID=%s rw quiet%s %s"\n"Boot to terminal"            "root=UUID=%s rw init=/sbin/$INIT%s %s"\n"Boot with minimal options"   "root=UUID=%s rw%s %s"\n' \
      "$ROOT_UUID" "$_btrfs_flag" "$_INITRD" "$ROOT_UUID" "$_btrfs_flag" "$_INITRD" "$ROOT_UUID" "$_btrfs_flag" "$_INITRD" >/mnt/boot/refind_linux.conf
  fi

  if [ "$BTRFS_SNAPSHOTS" = "1" ]; then
    mkdir -p /mnt/etc/snapper/hooks/post
    cat >/mnt/etc/snapper/hooks/post/refind-snapshot-update <<'HOOK'
#!/bin/bash
CONF=/boot/refind_linux.conf
sed -i '/Snapshot [0-9]/d' "$CONF"
find /.snapshots -maxdepth 2 -name info.xml 2>/dev/null | sort -rV | head -10 | while read -r xml; do
    num=$(basename "$(dirname "$xml")")
    date=$(grep -oP '(?<=<date>)[^<]+' "$xml" | head -1)
    root_uuid=$(findmnt -no UUID / 2>/dev/null)
    printf '"Snapshot %s (%s)"  "root=UUID=%s rw rootflags=subvol=@snapshots/%s/snapshot quiet"\n' \
        "$num" "$date" "$root_uuid" "$num" >> "$CONF"
done
HOOK
    chmod +x /mnt/etc/snapper/hooks/post/refind-snapshot-update
  fi
  ;;
esac

gauge 100 "Installation complete!"

# Unmount filesystems before final menu to prevent lockups
umount -R /mnt 2>/dev/null || true

# Offer AUR helper setup before final options
if [ "$PRIV_ESC" = "doas" ]; then
  echo ""
  echo "==> AUR Helper Setup"
  echo ""
  _aur=$(whiptail --title "$TITLE" --menu \
    "Select AUR Helper\n\nNote: yay is HEAVILY sudo-centric and causes headaches with doas.\nparu is recommended for doas-only systems." \
    15 70 3 \
    "paru" "paru (RECOMMENDED) — doas-native, no sudo headaches" \
    "yay" "yay — install sudo too (works but requires workarounds)" \
    "none" "None — use makepkg manually or skip AUR packages" \
    3>&1 1>&2 2>&3) || _aur="none"

  case "$_aur" in
  paru)
    echo "==> Installing paru from AUR (doas-compatible)..."
    echo "    (This may take several minutes - do not interrupt)"
    timeout 1200 artix-chroot /mnt bash <<PARU_INSTALL
pacman -S --noconfirm --needed git base-devel
git clone https://aur.archlinux.org/paru.git /tmp/paru
chown -R ${USERNAME}:${USERNAME} /tmp/paru
cd /tmp/paru
su -s /bin/bash ${USERNAME} -c 'MAKEFLAGS="-j\$(nproc)" makepkg --noconfirm -si' || true
rm -rf /tmp/paru
PARU_INSTALL
    if [ $? -eq 124 ]; then
      echo "==> Warning: paru build timed out (>20 mins). You can build it manually later."
    else
      echo "==> paru installed successfully"
    fi
    ;;
  yay)
    echo "==> Installing sudo (required for yay)..."
    timeout 30 artix-chroot /mnt pacman -S --noconfirm sudo
    echo "==> Installing yay from AUR..."
    echo "    (Note: yay will use sudo internally, not doas)"
    echo "    (Consider using paru instead for better doas integration)"
    echo "    (This may take several minutes - do not interrupt)"
    timeout 1200 artix-chroot /mnt bash <<YAY_INSTALL
pacman -S --noconfirm --needed git base-devel
git clone https://aur.archlinux.org/yay.git /tmp/yay
chown -R ${USERNAME}:${USERNAME} /tmp/yay
cd /tmp/yay
sudo -u ${USERNAME} bash -c 'MAKEFLAGS="-j\$(nproc)" makepkg --noconfirm -si' || true
rm -rf /tmp/yay
YAY_INSTALL
    if [ $? -eq 124 ]; then
      echo "==> Warning: yay build timed out (>20 mins). You can build it manually later."
    else
      echo ""
      echo "==> WARNING: You now have both doas and sudo."
      echo "    yay uses sudo internally and won't respect doas configuration."
      echo "    If you want pure doas, reinstall paru instead."
    fi
    ;;
  *)
    echo "==> Skipping AUR helper installation."
    echo "    You can install paru or yay manually after boot:"
    echo "    $ doas pacman -S base-devel git"
    echo "    $ git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si"
    ;;
  esac
  echo ""
fi

_end=$(whiptail --title "$TITLE" --menu \
  "Installation complete!\n\nWhat would you like to do?" \
  12 60 3 \
  "reboot" "Reboot into the new system" \
  "shell" "Drop to shell" \
  "exit" "Exit to live environment" \
  3>&1 1>&2 2>&3) || _end="exit"

case "$_end" in
reboot)
  reboot
  ;;
shell)
  echo ""
  echo "You are now at the shell. Type 'exit' to return."
  /bin/bash
  ;;
*)
  echo "Exiting. You can reboot manually with 'reboot' command when ready."
  ;;
esac
