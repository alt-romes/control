#!/usr/bin/env bash

if ! [[ -f macOS.qcow2 ]]
then
    echo "The macOS Catalina (macOS.qcow2) disk image is missing!"
    exit 1
fi
