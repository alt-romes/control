#!/usr/bin/env bash

source ../environment.sh

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6667-:22 \
    -hda debian.qcow2 \
    # -pflash $FIRMWAREDIR/OVMF.fd \
