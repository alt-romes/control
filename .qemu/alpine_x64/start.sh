#!/usr/bin/env bash

qemu-system-x86_64 \
    -m 8G \
    -smp 4 \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6666-:22 \
    -hda alpine.qcow2
    # -cdrom alpine-extended-3.17.2-x86_64.iso \
    # -boot d \
    # -hdb /dev/disk2
