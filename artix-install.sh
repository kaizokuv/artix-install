#!/bin/bash

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    whiptail --title "Error" --msgbox "This installer must be run as root." 10 60
    exit 1
fi

# Select Disk
DISK=$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme" | \
whiptail --menu "Select disk for installation" 20 80 10 \
$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme") \
3>&1 1>&2 2>&3)

# Handle cancellation
if [[ -z "$DISK" ]]; then exit 1; fi

SWAPSIZE=$(whiptail --inputbox "Enter swap size (e.g., 8G):" 10 60 "8G" 3>&1 1>&2 2>&3)

whiptail --yesno "This will erase ALL data on $DISK. Continue?" 12 60 || exit 1

# Unmount and clean up
swapoff -a
umount -R /mnt 2>/dev/null || true
rm -rf /mnt
mkdir -p /mnt

for p in $(lsblk -ln -o NAME "$DISK" | tail -n +2); do
    umount -l "/dev/$p" 2>/dev/null || true
done

fuser -km "$DISK" 2>/dev/null || true
dd if=/dev/zero of="$DISK" bs=1M count=10 status=none

# FIX: Reordered partitions -> EFI, SWAP, ROOT (rest of disk)
printf "label: gpt\n,1G,U\n,%s,S\n,,L\n" "$SWAPSIZE" | sfdisk "$DISK"

# FIX: Adjust partition numbers based on new order
if [[ "$DISK" == *"nvme"* ]]; then
    EFI="${DISK}p1"
    SWAP="${DISK}p2"
    ROOT="${DISK}p3"
else
    EFI="${DISK}1"
    SWAP="${DISK}2"
    ROOT="${DISK}3"
fi

# Format partitions
mkfs.fat -F32 "$EFI"
mkswap "$SWAP"
swapon "$SWAP"
mkfs.xfs -f "$ROOT"

# Mount partitions
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# ENHANCEMENT: Auto-detect CPU microcode
CPU_VENDOR=$(grep vendor_id /proc/cpuinfo | head -n 1 | awk '{print $3}')
if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    UCODE="amd-ucode"
else
    UCODE="intel-ucode"
fi

# Install Base System
basestrap /mnt \
base base-devel dinit elogind-dinit linux-zen linux-firmware $UCODE \
grub efibootmgr os-prober vim fastfetch \
networkmanager networkmanager-dinit dbus dbus-dinit opendoas git \
pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber rtkit-daemon

fstabgen -U /mnt >> /mnt/etc/fstab

# Chroot: Base config and Bootloader
artix-chroot /mnt /bin/bash -c "
set -e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

mkdir -p /etc/dinit.d/boot.d

# FIX: Added dbus to the services loop
for svc in dbus elogind NetworkManager rtkit-daemon; do
    ln -sf /etc/dinit.d/\$svc /etc/dinit.d/boot.d/\$svc
done

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
grub-mkconfig -o /boot/grub/grub.cfg
"

# FIX: Build an array safely for whiptail to prevent word-splitting bugs
readarray -t LOCALE_ARRAY < <(grep ' UTF-8' /etc/locale.gen | sed 's/^#//' | awk '{print $1, "-"}')
LOCALE=$(whiptail --title "Locale Selection" --menu "Select your locale" 20 60 12 "${LOCALE_ARRAY[@]}" 3>&1 1>&2 2>&3)

# Configure Locale
artix-chroot /mnt /bin/bash -c "
sed -i \"s/^#\$LOCALE UTF-8/\$LOCALE UTF-8/\" /etc/locale.gen
locale-gen
echo \"LANG=\$LOCALE\" > /etc/locale.conf
"

# Set Root Password
whiptail --msgbox "You will now set the root password." 10 60
artix-chroot /mnt /bin/bash -c "passwd"

# Setup User
USERNAME=$(whiptail --inputbox "Enter username:" 10 60 "user" 3>&1 1>&2 2>&3)

whiptail --msgbox "You will now set the password for $USERNAME." 10 60
artix-chroot /mnt /bin/bash -c "
useradd -m -G wheel -s /bin/bash $USERNAME
usermod -aG audio,video,realtime $USERNAME
echo 'permit :wheel' > /etc/doas.conf
passwd $USERNAME
"

# Clean up and exit
umount -R /mnt 2>/dev/null || true
sync

if whiptail --yesno "Installation complete. Reboot now?" 10 60; then
    reboot
else
    echo "You chose not to reboot. You may reboot manually."
fi
