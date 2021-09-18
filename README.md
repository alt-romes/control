## Control

This repository puts together everything needed to build a[read: my] home in any computer.
Base control sets up the dotfiles, utils/scripts, launch daemon on macos, and the homesite where write ups, albums, movies, ..., are organized and from where they can be published. Additionally some other parts are in movement and trying to find their place.
Setting up in any system is done 
Setting up from scratch (configuring the OS and downloading a pseudo-minimal environment) is supported for two operating systems:
- macOS with `system-zero-setup.sh`
- voidlinux with `void-system-zero-setup.sh`

## Architecture


`system-zero-setup.sh` sets up macOS from scratch.
`void-system-zero-setup.sh` sets up Void Linux from scratch.
`control-setup.sh` sets up the "control" environment by running the `dotfiles` set up scripts, setting up the launch daemon, among other actions


##  Installation

To setup a new macOS machine: fetch and run the `system-zero-setup.sh` script.
```
cd $HOME
curl -LO https://raw.githubusercontent.com/alt-romes/control/master/system-zero-setup.sh
chmod +x system-zero-setup.sh
./system-zero-setup.sh
```

To setup a new voidlinux machine: get curl, then fetch and run the `void-system-zero-setup.sh` script.
```
sudo xbps-install -u xbps
sudo xbps-install curl
curl -LO https://raw.githubusercontent.com/alt-romes/control/master/void-system-zero-setup.sh
chmod +x void-system-zero-setup.sh
./void-system-zero-setup.sh
```

To setup control on any computer clone the repo and run the `control-setup.sh` script
```
git clone https://github.com/alt-romes/control/
cd control
./control-setup.sh
```
