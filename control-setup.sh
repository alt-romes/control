#!/usr/bin/env bash

CONTROL=$(pwd)

echo
echo "Setting up control... for everything to work correctly, ssh and gpg must be installed"
echo "To clone some -control- submodules, a valid private ssh key is required."
read -r -p "Do you want to load a valid private ssh key? (y/n) "
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Move the ssh private key to ~/keys/sshkey"
    read -r -p "Input any key afterwards... "
    ssh-add ~/keys/sshkey
fi

echo "To decrypt the private dotfiles (which include, e.g., cryptographic keys),"
echo "a valid gnupg secret key is required."
read -r -p "Do you want to load a secret gnupg key? (y/n) "
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Move the gnupg secret key to ~/keys/gnupgkey.asc"
    read -r -p "Input any key afterwards... "
    gpg --import ~/keys/gnupgkey.asc
fi

echo "Initializing and updating submodules..."
git submodule update --init --recursive

# set up public dotfiles
cd ./dotfiles/public || exit 1
./setup.sh
cd "${CONTROL}" || exit 1

# set up private dotfiles
cd ./dotfiles/private/ || exit 1
./setup.sh
cd "${CONTROL}" || exit 1

read -p "macOS*: Set up launchd agent to run romes.initd script on startup? (y/n) " -r
if [[ $REPLY =~ ^[Yy]$ ]]
then
    # set romes.initd script to launch on startup
    mkdir -p ~/Library/LaunchAgents
    if [[ -f "$HOME/Library/LaunchAgents/romes.initd.plist" ]]
    then
        # first unload if file already exists
        launchctl unload ~/Library/LaunchAgents/romes.initd.plist
    fi
    cp launchd/romes.initd.plist "$HOME/Library/LaunchAgents/"
    launchctl load -w ~/Library/LaunchAgents/romes.initd.plist
fi
