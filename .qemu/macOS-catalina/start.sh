#!/usr/bin/env bash

OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
VMDIR=.
FIRMWAREDIR=$VMDIR/firmware

sudo qemu-system-x86_64 \
    -m 4G \
    -machine q35,accel=hvf \
    -smp 4,cores=2 \
    -cpu Penryn,vendor=GenuineIntel,kvm=on,+sse3,+sse4.2,+aes,+xsave,+avx,+xsaveopt,+xsavec,+xgetbv1,+avx2,+bmi2,+smep,+bmi1,+fma,+movbe,+invtsc \
    -device isa-applesmc,osk="$OSK" \
    -smbios type=2 \
    -drive if=pflash,format=raw,readonly,file="$FIRMWAREDIR/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,file="$FIRMWAREDIR/OVMF_VARS-1024x768.fd" \
    -device ich9-intel-hda -device hda-output \
    -usb -device usb-kbd -device usb-mouse \
    -netdev user,id=net0 \
    -device e1000-82545em,netdev=net0,id=net0,mac=52:54:00:c9:18:27 \
    -device ich9-ahci,id=sata \
    -drive id=ESP,if=none,format=qcow2,file=$VMDIR/ESP.qcow2 \
    -device ide-hd,bus=sata.2,drive=ESP \
    -drive id=SystemDisk,if=none,file=macOS.qcow2 \
    -device ide-hd,bus=sata.4,drive=SystemDisk \
    -drive id=USB,if=none,file=/dev/rdisk2 \
    -device ide-hd,bus=sata.3,drive=USB \
