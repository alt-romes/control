set -e
echo "System must be connected to the internet through an ethernet cable, or through WiFi with wpa_supplicant (and the dhcpcd service enabled)"

echo "Updating xbps (package manager)"
sudo xbps-install -u xbps

echo "Updating system"
sudo xbps-install -Su

echo "XBPS does not restart services when they are updated. To find processes running different versions than are present on disk, use the xcheckrestart tool provided by the xtools package."


# Power saving
echo "Power saving: Installing tlp"
sudo xbps-install tlp
echo "Enabling tlp service"
sudo ln -s /etc/sv/tlp/ /var/service/


# Configure network
echo "Configure network..."
echo "Set up and download networkmanager (daemon that manages Ethernet, Wifi, ... -- other network management services must be disabled)"
echo "Downloading NetworkManager"
echo "If the following fails, run xbps-install -Su again"
sudo xbps-install NetworkManager
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
sudo xbps-install xorg

echo "Installing openbox (window manager)"
sudo xbps-install openbox
echo "Installing openbox configuration app (obconf)"
sudo xbps-install obconf
echo "Installing picom (compositor)"
sudo xbps-install picom
echo "Note: picom might still be outdated in relation to rounded corners. In this case, download void-package, edit the picom template version and work with xbps-src (binutils required)"

echo "Installing background setter (feh)"
sudo xbps-install hsetroot

echo "Installing papirus icon theme and program to change folder color"
sudo xbps-install -S papirus-icon-theme
sudo xbps-install -S papirus-folders

# Fonts
echo "Fonts"
echo "Installing cozette bitmap font"
sudo xbps-install font-cozette
echo "Suggested: font-ibm-plex-ttf"
# sudo xbps-install font-ibm-plex-ttf

echo "Installing GNUPG"
sudo xbps-install gnupg
echo "TODO: Import keys (see macOS script)"


# Apps
sudo xbps-install Thunar # file manager
sudo xbps-install rxvt-unicode # terminal
sudo xbps-install vim
sudo xbps-install git
sudo xbps-install curl
sudo xbps-install firefox

# Utils
sudo xbps-install make
