#!/bin/bash

# ----------------------------------------
# Artix Linux Minimal Installer v2.0
# EFI, NVMe/SATA, swap, home, PipeWire, doas
# ----------------------------------------

# Must be run as root
if [[ $EUID -ne 0 ]]; then
    whiptail --title "Error" --msgbox "This installer must be run as root." 10 60
    exit 1
fi

# ------------------------
# Cleanup previous mounts
# ------------------------

echo "[*] Unmounting any leftover mounts on $DISK..."


umount -R /mnt 2>/dev/null || true
rm -rf /mnt
mkdir -p /mnt/

for part in $(lsblk -ln -o NAME "$DISK" | tail -n +2); do
    echo "[*] Unmounting /dev/$part ..."
    umount -R "/dev/$part" 2>/dev/null || true
done

echo "[*] Killing processes using $DISK ..."
fuser -k "$DISK" 2>/dev/null || true

if mount | grep -q "$DISK"; then
    echo "[!] Some partitions are still mounted. Attempting lazy unmount..."
    for part in $(lsblk -ln -o NAME "$DISK" | tail -n +2); do
        umount -l "/dev/$part" 2>/dev/null || true
    done
fi

echo "[*] Cleanup complete. Proceeding with partitioning..."

echo "[*] Cleanup complete. Proceeding with partitioning..."

echo "[*] Cleanup complete. Proceeding with partitioning..."

DISK=$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme" | \
whiptail --menu "Select disk for installation" 20 80 10 \
$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme") \
3>&1 1>&2 2>&3)

SWAPSIZE=$(whiptail --inputbox "Enter swap size (e.g., 8G):" 10 60 "8G" 3>&1 1>&2 2>&3)

whiptail --yesno "This will erase all data on $DISK. Continue?" 12 60 || exit 1

printf "label: gpt\n,1G,U\n,200G,L\n,%s,S\n,,L\n" "$SWAPSIZE" | sfdisk "$DISK"

echo "[*] Partitioning done."

if [[ "$DISK" == *"nvme"* ]]; then
    EFI="${DISK}p1"
    ROOT="${DISK}p2"
    SWAP="${DISK}p3"
    HOME="${DISK}p4"
else
    EFI="${DISK}1"
    ROOT="${DISK}2"
    SWAP="${DISK}3"
    HOME="${DISK}4"
fi

# ------------------------
# Format partitions
# ------------------------
mkfs.fat -F32 "$EFI"
mkfs.xfs -f "$ROOT"
mkfs.xfs -f "$HOME"
mkswap "$SWAP"
swapon "$SWAP"

# ------------------------
# Mount partitions
# ------------------------
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot
mkdir -p /mnt/home
mount "$HOME" /mnt/home

# ------------------------
# Start network time (host)
# ------------------------
dinitctl start ntpd || true

# ------------------------
# Install base system
# ------------------------
basestrap /mnt \
base \
base-devel \
dinit \
elogind-dinit \
linux-zen \
linux-firmware \
intel-ucode \
grub \
efibootmgr \
os-prober \
vim \
fastfetch \
networkmanager \
networkmanager-dinit \
opendoas \
git \
pipewire \
pipewire-alsa \
pipewire-pulse \
pipewire-jack \
wireplumber \
rtkit

# ------------------------
# Generate fstab
# ------------------------
fstabgen -U /mnt >> /mnt/etc/fstab

# ------------------------
# Enter chroot
# ------------------------
export USERNAME

artix-chroot /mnt /bin/bash <<EOF

set -e
export TERM=xterm-256color
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# ------------------------
# Locale selection
# ------------------------
LOCALE_LIST=\$(grep 'UTF-8' /etc/locale.gen | sed 's/^#//' | awk '{print \$1 " locale"}')

LOCALE=\$(whiptail \
--backtitle "Artix Linux Minimal Installer v2.0" \
--title "Step 1: Locale Selection" \
--menu "Select your locale:" \
40 80 20 \
\$LOCALE_LIST \
3>&1 1>&2 2>&3)

echo "[*] Applying locale \$LOCALE"
sed -i "s/^#\$LOCALE UTF-8/\$LOCALE UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=\$LOCALE" > /etc/locale.conf

# ------------------------
# Enable services
# ------------------------
dinitctl enable elogind
dinitctl enable ntpd
dinitctl enable NetworkManager
dinitctl enable rtkit

# ------------------------
# Configure GRUB
# ------------------------
sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || true
echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
grub-mkconfig -o /boot/grub/grub.cfg

# ------------------------
# Root password
# ------------------------
echo "[*] Set root password:"
passwd

# ------------------------
# Regular user + doas
# ------------------------
USERNAME=\$(whiptail --inputbox "Enter your username:" 10 60 "user" 3>&1 1>&2 2>&3)
useradd -m -G wheel -s /bin/bash "\$USERNAME"
usermod -aG audio,video,realtime "\$USERNAME"
echo "permit :wheel" > /etc/doas.conf

echo "[*] Set password for \$USERNAME"
passwd "\$USERNAME"

EOF

# ------------------------
# Cleanup
# ------------------------
echo "[*] Unmounting..."
umount -R /mnt 2>/dev/null || true
sync

echo "[✓] DONE. Rebooting..."
reboot
