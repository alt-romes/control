## Control

This repository puts together everything needed to build a[read: my] home in any computer.
Base control sets up the dotfiles, utils/scripts, launch daemon on macos, and the homesite where write ups, albums, movies, ..., are organized and from where they can be published. Additionally some other parts are in movement and trying to find their place.
Setting up in any system is done 
Setting up from scratch (configuring the OS and downloading a pseudo-minimal environment) is supported for two operating systems:
- macOS with `system-zero-setup.sh`
- voidlinux with `void-system-zero-setup.sh`

## Architecture

`dotfiles`
  - `public` contains all the publicly available dotfiles, and a script that sets them up through symlinks in ~
  - `private` contains all my private dotfiles, and a script that decrypts (some of) them with GnuPG and sets the symlinks in ~

`languages`
  - `japanese-deck` is a (WIP) anki deck for studying the core jōyō kanji (2k) and vocabulary (6k), paired with etymology from a chinese characters database (lacking on all public decks), most common reading, multiple languages translation, custom mnemonics, ... (again, WIP) (it's still finding its place here, but managing anki somehow through `control` would be quite interesting)

`launchd` contains scripts that are set up to run with macOS's `launchd` through the (also here) `.plist` files

`poemas` is my poetry record (50+) which I recently organized and that is still looking for a place to stay

`site` is my homepage / identity page, where write ups, movies, albums and other (only relevant - not a comprehensive list, for that check [projects (WIP)]()) projects or records end up (written in haskell :))

`unsorted` is unsorted from my first previous attempt at doing this (second way around - git submodules are cool :) )

`util`
  - `bin` contains custom scripts, and is added to the $PATH environment variable
  - `OVMF.fd` is a loader to boot VMs with UEFI with `qemu` built on Intel x86_64 macOS that is useful pre-built [[source repository]](https://github.com/tianocore/edk2)

`control-setup.sh` sets up the "control" environment by running the `dotfiles` set up scripts, setting up the launch daemon, among other actions

`system-zero-setup.sh` sets up macOS from scratch

`void-system-zero-setup.sh` sets up Void Linux from scratch


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
sudo xbps-install -Su xbps
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
