#!/usr/bin/env bash

echo "A network connection is required (use, e.g., sudo raspian-config)!"

sudo apt update

sudo apt install sway # comes preconfigured? at least it has the foot terminal

sudo useradd -mUG sudo romes
sudo passwd romes

sudo su romes
cd "$HOME" || exit

sudo apt install git vim

if [[ ! -d "$HOME/control" ]]
then
    git clone https://github.com/alt-romes/control.git
fi
 
// TODO ...
