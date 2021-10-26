#!/usr/bin/env bash

source ../environment.sh

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -pflash $FIRMWAREDIR/OVMF.fd \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6666-:22 \
    -hda voidlinux.qcow2 \
    -hdb /dev/rdisk2 \
    # -pflash $FIRMWAREDIR/OVMF.fd \