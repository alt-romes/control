#!/usr/bin/env bash

# This script will setup a grub menu entry that boots the Operating
# System into RAM. To this effect, an initramfs image is created with non-default
# "root mounting instructions":
#       Mount the root filesystem in a temporary directory other than the $NEWROOT
#       Mount a tmpfs filesystem in the $NEWROOT
#       Copy the contents of the temporary directory to the $NEWROOT (to the tmpfs)
# or so :)

set -e

echo "Program must be run as root"

# Change fstab to mount / with tmpfs filesystem
if ! grep -q "none / tmpfs defaults 0 0" /etc/fstab; then
    echo "Editing /etc/fstab"
    cp /etc/fstab /etc/fstab.bak
    sed -i -r "s/(UUID=(.*) \/ (.*))/# \1/" /etc/fstab
    echo "none / tmpfs defaults 0 0" >> /etc/fstab
    # TODO: Why can we still boot normally when the UUID=... / ext4 line in /etc/fstab is commented?
fi


# Change dracut module to create ramboot initramfs
DRACUT_MODULES=/usr/lib/dracut/modules.d

cp $DRACUT_MODULES/95rootfs-block/mount-root.sh $DRACUT_MODULES/95rootfs-block/mount-root.sh.bak

LINE_TO_CHANGE=$(awk '/while ! mount -t/ {print NR}' $DRACUT_MODULES/95rootfs-block/mount-root.sh)
head -n $((LINE_TO_CHANGE-1)) $DRACUT_MODULES/95rootfs-block/mount-root.sh > mount-root.sh.tmp
cat << END >> mount-root.sh.tmp
mkdir /ramboottmp
mount -t \${fstype:-auto} -o "\$rflags" "\${root#block:}" /ramboottmp \\
	&& ROOTFS_MOUNTED=yes
mount -t tmpfs -o size=100% none "\$NEWROOT"
cd "\$NEWROOT"
cp -rfa /ramboottmp/* "\$NEWROOT"
echo -n > /root/ramboot
umount /ramboottmp
END
tail -n +$((LINE_TO_CHANGE+4)) $DRACUT_MODULES/95rootfs-block/mount-root.sh >> mount-root.sh.tmp

mv mount-root.sh.tmp $DRACUT_MODULES/95rootfs-block/mount-root.sh

dracut /boot/initramfs-ramboot.img --force

cp $DRACUT_MODULES/95rootfs-block/mount-root.sh.bak $DRACUT_MODULES/95rootfs-block/mount-root.sh


# Change grub 40_custom to add RAM entry
if ! grep -q "initramfs-ramboot.img" /etc/grub.d/40_custom; then
    echo "Creating a grub entry"
    echo "menuentry 'Void GNU/Linux (RAM)' {" >> /etc/grub.d/40_custom
    awk '/^menuentry .Void/ {p=1;f=1}; {if (p==1) {a[NR] = $0}}; /}/ {if (f==1) {for (i in a) print a[i]}; f=0; delete a}' /boot/grub/grub.cfg | \
        tail -n +2 | \
        sed 's/initrd.*\/boot\/.*/initrd  \/boot\/initramfs-ramboot.img/' >> /etc/grub.d/40_custom
    update-grub
fi
