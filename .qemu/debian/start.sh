#!/usr/bin/env bash

qemu-system-aarch64 \
    -machine virt \
    -m 8G \
    -smp 4 \
    -hda debian.qcow2 \
    # -nographic
    # -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6667-:22 \
    # -cdrom ~/Downloads/debian-11.7.0-arm64-netinst.iso \
    # -boot d \
    # -usb -device usb-kbd -device usb-mouse \
    # -accel=hvf \
