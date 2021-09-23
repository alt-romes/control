#!/usr/bin/env bash

if ! [[ -f ubuntu-live ]]
then
    echo "The live ubuntu image is missing!"
    exit 1
fi
