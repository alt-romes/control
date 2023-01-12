#!/usr/bin/env bash

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6666-:22 \
    -hda alpine.qcow2 \
    # -cdrom alpine-standard-3.15.0-x86_64.iso \
    # -boot d \
    -hdb /dev/disk2
