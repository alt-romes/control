#!/usr/bin/env bash

qemu-system-x86_64 \
    -accel hvf \
    -m 4G \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::6667-:22 \
    -hda voidlinux.qcow2 \
    # -cdrom void-live-x86_64-20210930.iso \
    # -boot d
    # -hdb /dev/rdisk2 \
    # -pflash $FIRMWAREDIR/OVMF.fd \
