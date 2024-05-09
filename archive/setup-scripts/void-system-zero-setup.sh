#!/usr/bin/env bash

# ----- --- -----

function prompt_optinstall {
    read -r -p "Do you want to $1? (y/n) "
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo "Installing..."
        return 0
    else
        echo "Not installed."
        return 1
    fi
}

# ----- --- -----

echo "System must be connected to the internet through an ethernet cable, or through WiFi with wpa_supplicant (and the dhcpcd service enabled)"

echo "Updating xbps (package manager)"
sudo xbps-install -y -u xbps

echo "Updating system"
sudo xbps-install -y -Su

echo "XBPS does not restart services when they are updated. To find processes running different versions than are present on disk, use the xcheckrestart tool provided by the xtools package."

# Bash session
echo "source \$HOME/.bash_profile" > $HOME/.bashrc # bashrc for non-interactive sessions should load configuration in bash_profile

# Session and Seat Management
sudo xbps-install -y seatd
sudo ln -s /etc/sv/seatd/ /var/service/
sudo usermod -aG _seatd $(whoami)

# XDG_RUNTIME_DIR (required by pipewire pulseaudio replacement, wayland, ...)
echo "Make sure XDG_RUNTIME_DIR is exported and setup in .bash_profile to /run/user/\$(id -u)"

# Power saving
# Use acpid
echo "Power saving: Installing tlp"
sudo xbps-install -y tlp
echo "Enabling tlp service"
sudo ln -s /etc/sv/tlp/ /var/service/

# Network
echo "Configure network..."
echo "Set up and download networkmanager (daemon that manages Ethernet, Wifi, ... -- other network management services must be disabled)"
echo "Downloading NetworkManager"
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

# Audio
echo "Installing pipewire (audio)"
sudo xbps-install -y pipewire

# Fonts
# TODO: clean up dependency...
echo "Installing cozette bitmap font (required by some dotfiles)"
sudo xbps-install -y font-cozette
echo "Suggested font: (font-ibm-plex-ttf) sudo xbps-install -y font-ibm-plex-ttf"

echo "Installing GnuPG"
sudo xbps-install -y gnupg

# Programs
echo "Installing programs"
sudo xbps-install -y vim
sudo xbps-install -y git
sudo xbps-install -y curl
sudo xbps-install -y make

sudo xbps-install -y exa
sudo xbps-install -y pass
sudo xbps-install -y pywal

# Graphical session
prompt_optinstall "install and setup an Xorg graphical session" && {

    echo "Installing Xorg"
    sudo xbps-install -y xorg

    echo "Installing background setter"
    sudo xbps-install -y hsetroot

    echo "Installing picom (compositor)"
    sudo xbps-install -y picom
    echo "Note: picom might still be outdated regarding rounded corners. In this case, download void-package, edit the picom template version and work with xbps-src (binutils required)"

    prompt_optinstall "install the openbox window manager" && {

        echo "Installing openbox (window manager)"
        sudo xbps-install -y openbox
        echo "Installing openbox configuration app (obconf)"
        sudo xbps-install -y obconf
        echo "Installing openbox menu generator (required to configure and utilize generated menus)"
        sudo xbps-install -y obmenu-generator

        prompt_optinstall "install tint2 panel/taskbar" && {

            echo "Installing tint2 (panel/taskbar) and configurator"
            sudo xbps-install -y tint2
            sudo xbps-install -y tint2conf
        }

        prompt_optinstall "install rofi" && {

            echo "Installing Rofi"
            sudo xbps-install -y rofi
        }
    }

    echo "install rxvt-unicode terminal"
    sudo xbps-install -y rxvt-unicode # terminal

}

prompt_optinstall "install and setup a Wayland graphical session" && {

    sudo xbps-install -y wayland
    sudo xbps-install -y mesa-dri
    sudo xbps-install -y qt5-wayland

    prompt_optinstall "install Sway compositor" && {
        sudo xbps-install -y sway
    }

    prompt_optinstall "install Wayfire compositor" && {
        sudo xbps-install -y wayfire
        sudo xbps-install -y wf-shell
    }

    sudo xbps-install -y alacritty

}

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
sudo xbps-install -y qutebrowser

echo "Suggestions:"
echo "git clone https://github.com/pystardust/ani-cli && \\
    mkdir -p $HOME/.local/bin && \\
    cp ani-cli/ani-cli $HOME/.local/bin/"
echo "sudo xbps-install -y anki"
echo "sudo xbps-install -y krita"
echo "sudo xbps-install -y firefox"

echo "TODO: Graphic Drivers"
