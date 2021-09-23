#!/usr/bin/env bash

cat << EOF

# 1) Create qemu disk, format qcow2, 5GB
sudo qemu-img create -f qcow2 disk.qcow 5G

# 2) qemu-system-x86_64 with some sensible options (4G RAM, hvf accel, UEFI firmware, port 22 guest -> 5555 host, USB passthrough)
sudo qemu-system-x86_64 \
    -m 4G \
    -accel hvf \
    -pflash control/util/OVMF.fd \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 \
    -usb -device usb-kbd -device usb-mouse \
    -hdb /dev/rdisk2 \
    -hda ~/voidlinux.qcow
    # -cdrom void-live-x86_64-20210218.iso \

EOF
