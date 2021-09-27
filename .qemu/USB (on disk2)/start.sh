#!/usr/bin/env bash

source ../environment.sh

sudo qemu-system-x86_64 \
    -m 4G \
    -accel hvf \
    -pflash $FIRMWAREDIR/OVMF.fd \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 \
    -hda /dev/disk2 \

