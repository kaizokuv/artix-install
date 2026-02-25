#!/bin/bash

set -e

DISK="/dev/nvme0n1"
EFI="${DISK}p1"
ROOT="${DISK}p2"

echo "[*] Formatting partitions..."

mkfs.xfs -L ROOT "$ROOT" -f
mkfs.fat -F 32 "$EFI"
fatlabel "$EFI" ESP

echo "[*] Mounting partitions..."

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

echo "[*] Starting network time..."
dinitctl start ntpd || true

echo "[*] Installing base system..."

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
fastfetch

echo "[*] Generating fstab..."

fstabgen -U /mnt >> /mnt/etc/fstab

echo "[*] Configuring system..."

artix-chroot /mnt /bin/bash <<EOF

set -e

echo "[*] Setting locale..."

sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "[*] Enabling services..."

dinitctl enable elogind
dinitctl enable ntpd

echo "[*] Configuring GRUB..."

sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || true
echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

grub-install \
--target=x86_64-efi \
--efi-directory=/boot \
--bootloader-id=grub

grub-mkconfig -o /boot/grub/grub.cfg

echo "[*] Set root password NOW:"
passwd

EOF

echo "[*] Unmounting..."

umount -R /mnt

echo "[✓] DONE. Reboot."
