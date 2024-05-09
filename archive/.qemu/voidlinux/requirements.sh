#!/usr/bin/env bash

if ! [[ -f voidlinux.qcow2 ]]
then
    echo "The void linux (voidlinux.qcow2) disk image is missing!"
    exit 1
fi
