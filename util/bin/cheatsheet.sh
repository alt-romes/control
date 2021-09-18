#!/usr/bin/env bash

cat << EOF

# Create qemu disk, format qcow2, 5GB
sudo qemu-img create -f qcow2 disk.qcow 5G

# Run voidlinux cdrom image with qemu, 4G RAM, macOS accelerator (hvf), USB on /dev/sdb, with UEFI boot loader (built OVMF for Intel macOS)
sudo qemu-system-x86_64 -m 4096 -accel hvf -cdrom void-live-x86_64-20210218.iso -hda disk.qcow -hdb /dev/disk2 -pflash control/util/OVMF.fd

# Run UEFI bootable OS from first external drive
sudo qemu-system-x86_64 -accel hvf -m 4096 -pflash control/util/OVMF.fd -hda /dev/disk2

EOF
