#!/usr/bin/env bash

cat << EOF

# 1) Create qemu disk, format qcow2, 5GB
qemu-img create -f qcow2 disk.qcow2 5G

EOF
