#!/usr/bin/env bash

echo "Updating control (recursively) from remote..."
echo "WARNING: This (reversible) action will update *all* submodules from HEAD, and might generate conflicts with the configurations."
read -r -p "Continue? (y/n) "
if [[ $REPLY =~ ^[Yy]$ ]]
then
    git submodule update --recursive --remote --merge
fi
