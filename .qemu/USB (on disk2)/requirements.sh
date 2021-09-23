#!/usr/bin/env bash

if ! [[ -e /dev/rdisk2 ]]
then
    echo "No disk available at /dev/disk2!"
    exit 1
fi
