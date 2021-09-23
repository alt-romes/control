#!/usr/bin/env bash

echo "(4) Setting variables..."
echo "(4) Set -- OSK VMDIR OVMF"
OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
VMDIR=$HOME/control/util/qemu
OVMF=$VMDIR/firmware

cat << EOF

# 1) Create qemu disk, format qcow2, 5GB
sudo qemu-img create -f qcow2 disk.qcow 5G

# 2) Run voidlinux cdrom image with qemu, 4G RAM, macOS accelerator (hvf), USB on /dev/sdb, with UEFI boot loader (built OVMF for Intel macOS)
sudo qemu-system-x86_64 \
    -m 4096 \
    -accel hvf \
    -cdrom void-live-x86_64-20210218.iso \
    -pflash control/util/OVMF.fd \
    -hda disk.qcow \
    -hdb /dev/disk2 \

# 3) Run voidlinux disk image with (my) USB mouse and ssh on port 5555
qemu-system-x86_64 \
    -accel hvf \
    -m 4096 \
    -pflash ~/control/util/OVMF.fd \
    -usb -device usb-kbd -device usb-mouse \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 \
    -hda ~/voidlinux.qcow

# 4) Run macos disk image
qemu-system-x86_64 \
    -m 4G \
    -machine q35,accel=hvf \
    -smp 4,cores=2 \
    -cpu Penryn,vendor=GenuineIntel,kvm=on,+sse3,+sse4.2,+aes,+xsave,+avx,+xsaveopt,+xsavec,+xgetbv1,+avx2,+bmi2,+smep,+bmi1,+fma,+movbe,+invtsc \
    -device isa-applesmc,osk="$OSK" \
    -smbios type=2 \
    -drive if=pflash,format=raw,readonly,file="$OVMF/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,file="$OVMF/OVMF_VARS-1024x768.fd" \
    -device ich9-intel-hda -device hda-output \
    -usb -device usb-kbd -device usb-mouse \
    -netdev user,id=net0 \
    -device e1000-82545em,netdev=net0,id=net0,mac=52:54:00:c9:18:27 \
    -device ich9-ahci,id=sata \
    -drive id=ESP,if=none,format=qcow2,file=$VMDIR/ESP.qcow2 \
    -device ide-hd,bus=sata.2,drive=ESP \
    -drive id=SystemDisk,if=none,file=$HOME/macOS.qcow2 \
    -device ide-hd,bus=sata.4,drive=SystemDisk \


EOF
