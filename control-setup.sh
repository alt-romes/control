#!/usr/bin/env bash

CONTROL=$(pwd)

# set up public dotfiles
cd ./dotfiles/public || exit 1
./setup.sh
cd "${CONTROL}" || exit 1

# set up private dotfiles
cd ./dotfiles/private/ || exit 1
./setup.sh
cd "${CONTROL}" || exit 1

read -p "Set up launchd agent to run romes.initd script on startup? (y/n) " -r
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
