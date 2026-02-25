#!/bin/bash
set -e 

# --- PRE-FLIGHT ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# --- NETWORK CHECK ---
if ! ping -c 1 artixlinux.org &>/dev/null; then
    whiptail --title "Network Offline" --msgbox "Launching nmtui to connect..." 10 60
    nmtui
    ping -c 1 artixlinux.org &>/dev/null || { echo "Offline. Exiting."; exit 1; }
fi

# --- USER INPUT ---
DISK=$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme" | \
whiptail --menu "Select installation disk" 20 80 10 \
$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme") 3>&1 1>&2 2>&3)

[[ -z "$DISK" ]] && exit 1
SWAPSIZE=$(whiptail --inputbox "Enter swap size (e.g., 8G):" 10 60 "8G" 3>&1 1>&2 2>&3)
USERNAME=$(whiptail --inputbox "Enter username:" 10 60 "user" 3>&1 1>&2 2>&3)
PASSWORD=$(whiptail --passwordbox "Enter password for root and $USERNAME:" 10 60 3>&1 1>&2 2>&3)

# --- CLEANUP & PARTITIONING ---
swapoff -a || true
umount -R /mnt 2>/dev/null || true
wipefs -af "$DISK"
dd if=/dev/zero of="$DISK" bs=1M count=1 conv=notrunc
# Create partitions
printf "label: gpt\n,1G,U\n,%s,S\n,,L\n" "$SWAPSIZE" | sfdisk --force "$DISK"
blockdev --rereadpt "$DISK" || true
udevadm settle && sleep 2

# Identify partitions
[[ "$DISK" == *"nvme"* ]] && P="p" || P=""
EFI="${DISK}${P}1"; SWAP="${DISK}${P}2"; ROOT="${DISK}${P}3"

# --- FORMAT & MOUNT ---
mkfs.fat -F32 "$EFI"
mkswap -f "$SWAP" && swapon "$SWAP"
mkfs.xfs -f "$ROOT"
mount "$ROOT" /mnt
mkdir -p /mnt/boot && mount "$EFI" /mnt/boot

# --- BASESTRAP + RECOMMENDED APPS ---
# Removed 'sudo', added 'opendoas' and essentials
echo "Installing base system and essential apps..."
pacman -Sy --noconfirm artix-keyring archlinux-keyring || true

basestrap /mnt base base-devel dinit elogind-dinit linux-zen linux-firmware \
intel-ucode grub efibootmgr networkmanager-dinit dbus-dinit opendoas \
htop nvtop neovim fastfetch git bat lsd tldr \
pipewire pipewire-pulse wireplumber alsa-utils

fstabgen -U /mnt >> /mnt/etc/fstab

# --- CHROOT CONFIG ---
artix-chroot /mnt /bin/bash <<EOF
set -e
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
grub-mkconfig -o /boot/grub/grub.cfg

mkdir -p /etc/dinit.d/boot.d
for svc in dbus elogind NetworkManager; do
    ln -sf /etc/dinit.d/\$svc /etc/dinit.d/boot.d/\$svc
done

# DOAS CONFIG (The Sudo Killer)
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo 'permit :wheel' > /etc/doas.conf
# Optional: Alias doas to sudo for muscle memory
echo "alias sudo='doas'" >> /home/$USERNAME/.bashrc
EOF

# --- WRAP UP ---
umount -R /mnt
sync
whiptail --title "Complete" --msgbox "Artix installed successfully without sudo!" 10 60
