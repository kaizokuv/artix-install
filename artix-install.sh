#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- PRE-FLIGHT ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# --- DISK SELECTION ---
DISK=$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme" | \
whiptail --menu "Select installation disk" 20 80 10 \
$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme") 3>&1 1>&2 2>&3)

SWAPSIZE=$(whiptail --inputbox "Enter swap size (e.g., 8G):" 10 60 "8G" 3>&1 1>&2 2>&3)

# --- THE CLEANUP (Preventing the Read-Only error) ---
echo "Clearing existing mounts and partition signatures..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

# --- PARTITIONING ---
# 1: EFI (1G), 2: Swap (User choice), 3: Root (The rest)
printf "label: gpt\n,1G,U\n,%s,S\n,,L\n" "$SWAPSIZE" | sfdisk --force "$DISK"
udevadm settle

# Identify partitions
if [[ "$DISK" == *"nvme"* ]]; then
    EFI="${DISK}p1"; SWAP="${DISK}p2"; ROOT="${DISK}p3"
else
    EFI="${DISK}1"; SWAP="${DISK}2"; ROOT="${DISK}3"
fi

# --- FORMATTING ---
mkfs.fat -F32 "$EFI"
mkswap -f "$SWAP"
swapon "$SWAP"
mkfs.xfs -f "$ROOT"

# --- MOUNTING ---
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- BASESTRAP ---
# We do this visibly so you can see if the network or keys fail
echo "Starting basestrap..."
basestrap /mnt base base-devel dinit elogind-dinit linux-zen linux-firmware \
intel-ucode grub efibootmgr networkmanager-dinit dbus-dinit opendoas

fstabgen -U /mnt >> /mnt/etc/fstab

# --- CHROOT CONFIG ---
artix-chroot /mnt /bin/bash <<EOF
set -e
# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
grub-mkconfig -o /boot/grub/grub.cfg

# Services
mkdir -p /etc/dinit.d/boot.d
for svc in dbus elogind NetworkManager; do
    ln -sf /etc/dinit.d/\$svc /etc/dinit.d/boot.d/\$svc
done

# User setup
echo "root:password" | chpasswd
useradd -m -G wheel user
echo "user:password" | chpasswd
echo 'permit :wheel' > /etc/doas.conf
EOF

# --- WRAP UP ---
umount -R /mnt
sync
echo "Done! You can now reboot."
