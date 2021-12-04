#!/usr/bin/env bash

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 \
    -hda kali.qcow2 \
    # -hdb /dev/rdisk2 \
