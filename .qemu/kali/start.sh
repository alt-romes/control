#!/usr/bin/env bash

source ../environment.sh

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 \
    -hda kali.qcow2 \
    # -hdb /dev/rdisk2 \
    # -pflash $FIRMWAREDIR/OVMF.fd \
