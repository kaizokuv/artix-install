#!/bin/bash
set -e 

# --- PRE-FLIGHT ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# --- NETWORK CHECK ---
echo "Checking internet connection..."
if ! ping -c 1 artixlinux.org &>/dev/null; then
    whiptail --title "Network Offline" --msgbox "Internet not detected. Launching nmtui to connect..." 10 60
    nmtui
    if ! ping -c 1 artixlinux.org &>/dev/null; then
        echo "Network still offline. Exiting."
        exit 1
    fi
fi

# --- USER INPUT ---
DISK=$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme" | \
whiptail --menu "Select installation disk" 20 80 10 \
$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme") 3>&1 1>&2 2>&3)

[[ -z "$DISK" ]] && exit 1

SWAPSIZE=$(whiptail --inputbox "Enter swap size (e.g., 8G):" 10 60 "8G" 3>&1 1>&2 2>&3)
USERNAME=$(whiptail --inputbox "Enter username:" 10 60 "user" 3>&1 1>&2 2>&3)
PASSWORD=$(whiptail --passwordbox "Enter password for both root and $USERNAME:" 10 60 3>&1 1>&2 2>&3)

# --- THE CLEANUP ---
echo "Nuking partition metadata..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true

# Zero out primary and backup GPT headers
wipefs -af "$DISK"
dd if=/dev/zero of="$DISK" bs=1M count=1 conv=notrunc
DISK_SIZE=$(blockdev --getsize64 "$DISK")
dd if=/dev/zero of="$DISK" bs=1M count=1 seek=$(( (DISK_SIZE / 1048576) - 1 )) conv=notrunc 2>/dev/null

# --- PARTITIONING ---
echo "Creating new partition table..."
printf "label: gpt\n,1G,U\n,%s,S\n,,L\n" "$SWAPSIZE" | sfdisk --force "$DISK"

# REPLACEMENT FOR PARTPROBE
blockdev --rereadpt "$DISK" || true
udevadm settle
sleep 2 

if [[ "$DISK" == *"nvme"* ]]; then
    EFI="${DISK}p1"; SWAP="${DISK}p2"; ROOT="${DISK}p3"
else
    EFI="${DISK}1"; SWAP="${DISK}2"; ROOT="${DISK}3"
fi

# --- FORMATTING & MOUNTING ---
mkfs.fat -F32 "$EFI"
mkswap -f "$SWAP"
swapon "$SWAP"
mkfs.xfs -f "$ROOT"

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- BASESTRAP ---
echo "Updating keyrings and starting basestrap..."
pacman -Sy --noconfirm artix-keyring archlinux-keyring || true

basestrap /mnt base base-devel dinit elogind-dinit linux-zen linux-firmware \
intel-ucode grub efibootmgr networkmanager-dinit dbus-dinit opendoas

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

echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo 'permit :wheel' > /etc/doas.conf
EOF

# --- WRAP UP ---
umount -R /mnt
sync
whiptail --title "Complete" --msgbox "Installation finished. You can now reboot." 10 60
