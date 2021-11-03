#!/usr/bin/env bash

source ../environment.sh

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6666-:22 \
    -hda alpine.qcow2 \
    -cdrom alpine-standard-3.14.2-x86_64.iso \
    # -boot d \
    # -pflash $FIRMWAREDIR/OVMF.fd \
