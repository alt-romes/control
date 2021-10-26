#!/usr/bin/env bash

echo "System must be connected to the internet through an ethernet cable, or through WiFi with wpa_supplicant (and the dhcpcd service enabled)"

echo "Updating xbps (package manager)"
sudo xbps-install -y -u xbps

echo "Updating system"
sudo xbps-install -y -Su

echo "XBPS does not restart services when they are updated. To find processes running different versions than are present on disk, use the xcheckrestart tool provided by the xtools package."

# Session and Seat Management
# TODO: Don't understand elogind, but it sets XDG RUNTIME DIR for me
sudo xbps-install -y elogind # install elogind
# Disable acpid bc of conflicts with elogind
sudo rm -rf /var/service/acpid/
# Enable elogind service (still don't understand why), but it'll replace acpid
sudo ln -s /etc/sv/elogind/ /var/service/


# Power saving
echo "Power saving: Installing tlp"
sudo xbps-install -y tlp
echo "Enabling tlp service"
sudo ln -s /etc/sv/tlp/ /var/service/


# Configure network
echo "Configure network..."
echo "Set up and download networkmanager (daemon that manages Ethernet, Wifi, ... -- other network management services must be disabled)"
echo "Downloading NetworkManager"
echo "If the following fails, run xbps-install -Su again"
sudo xbps-install -y NetworkManager
echo "Disabling dhcpcd service"
sudo rm /var/service/dhcpcd
echo "Enabling dbus service (NetworkManager uses it)"
sudo ln -s /etc/sv/dbus/ /var/service/
echo "Enabling networkmanager service"
sudo ln -s /etc/sv/NetworkManager/ /var/service/
echo "Users of NetworkManager must belong to the network group"
sudo usermod -a -G network $(whoami)
echo "NetworkManager is installed. Run nmcli or nmtui to check for a connection"


# Graphical session
echo "Graphical session..."
echo "Installing Xorg"
sudo xbps-install -y xorg

echo "Installing openbox (window manager)"
sudo xbps-install -y openbox
echo "Installing openbox configuration app (obconf)"
sudo xbps-install -y obconf
echo "Installing openbox menu generator (required to configure and utilize generated menus)"
sudo xbps-install -y obmenu-generator
echo "Installing picom (compositor)"
sudo xbps-install -y picom
echo "Note: picom might still be outdated in relation to rounded corners. In this case, download void-package, edit the picom template version and work with xbps-src (binutils required)"

echo "Installing background setter"
sudo xbps-install -y hsetroot

# echo "Installing Rofi"
# sudo xbps-install -y rofi

echo "Install pipewire (audio)"
sudo xbps-install -y pipewire

# Fonts
echo "Fonts"
echo "Installing cozette bitmap font"
sudo xbps-install -y font-cozette
echo "Suggested: font-ibm-plex-ttf"
# sudo xbps-install -y font-ibm-plex-ttf

echo "Installing GnuPG"
sudo xbps-install -y gnupg



# Programs
echo "Installing programs"
sudo xbps-install -y rxvt-unicode # terminal
sudo xbps-install -y vim
sudo xbps-install -y git
sudo xbps-install -y curl
sudo xbps-install -y make

sudo xbps-install -y exa
sudo xbps-install -y pass
sudo xbps-install -y pywal

# Control

echo "Start ssh-agent"
eval `ssh-agent -s`

if [[ ! -d "$HOME/control" ]]
then
    git clone https://github.com/alt-romes/control.git
fi

cd control || exit 1
git pull

source control-setup.sh # set up `control`

echo "Changing control remote to use ssh"
git remote set-url origin git@github.com:alt-romes/control.git

echo "Installing more programs"
sudo xbps-install -y anki

echo "Suggestions:"
echo "sudo xbps-install -y krita"
echo "sudo xbps-install -y firefox"

echo "TODO: Graphic Drivers"
