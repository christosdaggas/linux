#!/bin/bash

set -e

USERNAME=$(logname)
USERID=$(id -u "$USERNAME")
GROUPID=$(id -g "$USERNAME")

echo "=== Available Disks ==="
DISKS=($(lsblk -dpno NAME,TYPE | grep "disk" | awk '{print $1}'))
i=1
for DISK in "${DISKS[@]}"; do
    SIZE=$(lsblk -dnbo SIZE "$DISK")
    HUMAN_SIZE=$(numfmt --to=iec-i --suffix=B "$SIZE")
    echo "[$i] $DISK ($HUMAN_SIZE)"
    ((i++))
done
echo "========================"

read -rp "Enter the number of the disk you want to mount: " DISK_NUMBER
INDEX=$((DISK_NUMBER - 1))
SELECTED_DISK="${DISKS[$INDEX]}"

if [ -z "$SELECTED_DISK" ]; then
    echo "❌ Invalid selection."
    exit 1
fi

PARTITION="${SELECTED_DISK}1"
if [ ! -b "$PARTITION" ]; then
    echo "⚠️ No partition found on $SELECTED_DISK. You must partition it first."
    exit 1
fi

# Check for LUKS encryption
if sudo cryptsetup isLuks "$PARTITION"; then
    echo "🔒 This disk is encrypted with LUKS. You'll need to set up a keyfile or enter password on boot."
    echo "❌ Exiting for safety."
    exit 1
fi

FS_TYPE=$(blkid -s TYPE -o value "$PARTITION")
if [ -z "$FS_TYPE" ]; then
    echo "⚠️ No filesystem found on $PARTITION. Not mounting."
    exit 1
fi

read -rp "Enter a name for the mount folder (e.g., data, backup): " MOUNT_NAME
MOUNT_DIR="/mnt/$MOUNT_NAME"
mkdir -p "$MOUNT_DIR"

echo "🔧 Mounting $PARTITION to $MOUNT_DIR"
mount "$PARTITION" "$MOUNT_DIR"

UUID=$(blkid -s UUID -o value "$PARTITION")
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_DIR $FS_TYPE defaults,uid=$USERID,gid=$GROUPID 0 2" >> /etc/fstab
    echo "✅ Added to /etc/fstab for permanent mount"
else
    echo "ℹ️ Already exists in /etc/fstab"
fi

echo "🔧 Fixing permissions for user: $USERNAME"
chown -R "$USERNAME:$USERNAME" "$MOUNT_DIR"

echo "✅ $PARTITION mounted and accessible by $USERNAME without sudo"

read -rp "Do you want to reboot now? [y/N]: " RESPONSE
if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    sleep 2
    reboot
else
    echo "Reboot skipped."
fi
