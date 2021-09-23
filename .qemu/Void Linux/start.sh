#!/usr/bin/env bash

source ../environment.sh

echo "TODO: Download ubuntu live"

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -pflash $FIRMWAREVM/OVMF.fd \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 \
    -hda voidlinux.qcow2

