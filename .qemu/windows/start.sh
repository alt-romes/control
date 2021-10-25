#!/usr/bin/env bash

source ../environment.sh

qemu-system-x86_64 \
    -m 4G -vga std -net nic,model=e1000 -net user -usbdevice tablet\
    -boot d \
    -pflash /Users/romes/projects/edk2/Build/OvmfX64/DEBUG_XCODE5/FV/OVMF_CODE.fd \
    -cdrom ./windows.iso \
    -hda ./disk.qcow2 \
    -usb -device usb-kbd -device usb-mouse \

