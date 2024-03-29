#!/usr/bin/env bash

cat << EOF

# 1) Create qemu disk, format qcow2, 5GB
qemu-img create -f qcow2 disk.qcow2 5G

# 2) Create a RAM Disk in macOS with 1GB (2048 blocks equals 1MB)
diskutil erasedisk APFS "RAMDisk" \`hdiutil attach -nomount ram://$((2048*1024))\`

EOF

cat << EOF

# 3) GHC development

./hadrian/ghci    # quick build
./hadrian/build   # full build
./hadrian/build --flavour=default+no_profiled_libs+omit_pragmas stage2:exe:haddock -j --freeze1 # quick haddock build

EOF
