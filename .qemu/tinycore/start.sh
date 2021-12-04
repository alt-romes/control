#!/usr/bin/env bash

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6666-:22 \
    -hda tinycore.qcow2 \
    # -cdrom Core-current.iso \
    # -boot d \
    # -pflash $FIRMWAREDIR/OVMF.fd \
