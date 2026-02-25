#!/bin/bash
DISK=$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme" | \
whiptail --menu "Select disk" 20 60 10 \
$(lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/nvme") \
3>&1 1>&2 2>&3)

SWAPSIZE=$(whiptail --inputbox "Swap size:" 10 60 "8G" 3>&1 1>&2 2>&3)

whiptail --yesno "Erase $DISK ?" 10 60 || exit 1

printf "label: gpt\n,1G,U\n,200G,L\n,%s,S\n,,L\n" "$SWAPSIZE" | sfdisk "$DISK"

echo "[*] Partitioning.."

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


mkfs.fat -F32 "$EFI"
mkfs.xfs -f "$ROOT"
mkfs.xfs -f "$HOME"
mkswap "$SWAP"
swapon "$SWAP"

mount "$ROOT" /mnt
mkdir /mnt/boot
mount "$EFI" /mnt/boot
mkdir /mnt/home
mount "$HOME" /mnt/home

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
fastfetch \
networkmanager \
networkmanager-dinit \
opendoas \
git \
pipewire-alsa \
pipewire-pulse \
pipewire-jack
wireplumber \
rtkit

echo "[*] Generating fstab..."

fstabgen -U /mnt >> /mnt/etc/fstab

artix-chroot /mnt /bin/bash <<'EOF'

set -e
export TERM=xterm-256color

echo "[*] Selecting locale..."

LOCALE_LIST=$(grep 'UTF-8' /etc/locale.gen | sed 's/^#//' | awk '{print $1 " locale"}')

LOCALE=$(whiptail \
--backtitle "Artix Linux Minimal Installer v1.0" \
--title "Step 3: Locale Selection" \
--menu "Select your locale:" \
20 60 15 \
$LOCALE_LIST \
3>&1 1>&2 2>&3)

echo "[*] Applying locale $LOCALE"

sed -i "s/^#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "[*] Enabling services..."

dinitctl enable elogind
dinitctl enable ntpd
dinitctl enable NetworkManager
dinitctl enable rtkit

echo "[*] Configuring GRUB..."

sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || true
echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

grub-install \
--target=x86_64-efi \
--efi-directory=/boot \
--bootloader-id=grub

grub-mkconfig -o /boot/grub/grub.cfg

echo "[*] Set root password:"
passwd

USERNAME=$(whiptail --inputbox "Enter your username:" 10 60 "user" 3>&1 1>&2 2>&3)
useradd -m -G wheel -s /bin/bash "$USERNAME"
usermod -aG audio,video,realtime "$USERNAME"
echo "permit :wheel" > /etc/doas.conf

echo "[*] Set password for $USERNAME"
passwd "$USERNAME"

EOF

echo "[*] Unmounting..."

umount -R /mnt

echo "[✓] DONE. Reboot."
