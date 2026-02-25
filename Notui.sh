#!/bin/bash

# 1. Variables (Set these first)
DISK="/dev/sda" # Change this to your target (e.g., /dev/nvme0n1)
USER="yourname"
PASS="password"

# 2. Clean up and Partitioning
umount -R /mnt 2>/dev/null
swapoff -a
# EFI: 1G, Swap: 8G, Root: Remainder
printf "label: gpt\n,1G,U\n,8G,S\n,,L\n" | sfdisk "$DISK"

# 3. Detect Partition Names
if [[ "$DISK" == *"nvme"* ]]; then
    P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"
else
    P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"
fi

# 4. Formatting & Mounting (The Foundations)
mkfs.fat -F32 "$P1"
mkswap "$P2"
swapon "$P2"
mkfs.xfs -f "$P3"

mount "$P3" /mnt
mkdir -p /mnt/boot
mount "$P1" /mnt/boot

# 5. The Critical Basestrap
# I added 'artix-keyring' here just to be safe.
basestrap /mnt base base-devel dinit elogind-dinit linux-zen linux-firmware \
intel-ucode grub efibootmgr networkmanager-dinit dbus-dinit opendoas

# 6. Generate FSTAB (If this fails, it boots read-only or not at all)
fstabgen -U /mnt >> /mnt/etc/fstab

# 7. The Chroot "Big Block"
# We use a HEREDOC here to ensure the commands run inside the new system
artix-chroot /mnt <<EOF
# Set Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
grub-mkconfig -o /boot/grub/grub.cfg

# Users & Permissions
echo "root:$PASS" | chpasswd
useradd -m -G wheel $USER
echo "$USER:$PASS" | chpasswd
echo "permit :wheel" > /etc/doas.conf

# Enable Services (Dinit style)
mkdir -p /etc/dinit.d/boot.d
ln -s /etc/dinit.d/NetworkManager /etc/dinit.d/boot.d/
ln -s /etc/dinit.d/dbus /etc/dinit.d/boot.d/
EOF

echo "Done. Unmounting..."
umount -R /mnt
echo "Setup complete. Type 'reboot' if no errors were seen above."
