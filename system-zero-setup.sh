#!/usr/bin/env bash

# Install Developer tools
xcode-select --install

# Install Homebrew
if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)";
fi;
brew update

BREW_PREFIX=$(brew --prefix)

brew install coreutils

# Install bash v5 with completion
brew install bash
brew install bash-completion@2

# Set bash v5 as the default shell
if ! grep -Fq "${BREW_PREFIX}/bin/bash" /etc/shells; then
  # brew_prefix/bin/bash must be in the /etc/shells file to be a valid shell to change to with chsh (`man chsh`)
  echo "${BREW_PREFIX}/bin/bash" | sudo tee -a /etc/shells;
  chsh -s "${BREW_PREFIX}/bin/bash";
fi;

function prompt_optinstall {
    read -r -p "Do you want to install $1? (y/n) "
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo "Installing..."
        return 0
    else
        echo "Not installed."
        return 1
    fi
}

echo "Current git version: $(/usr/bin/git --version)"
prompt_optinstall "a possibly more recent git" && brew install git

echo "Current vim version: $(/usr/bin/vim --version)"
echo "(WARNING: The following installation might break pywal)"
echo "If it does, run 'brew uninstall vim' to attempt a fix"
prompt_optinstall "a possibly more recent vim (from --HEAD)" && brew install vim --HEAD

echo "Current ssh version: $(/usr/bin/ssh -V)"
prompt_optinstall "a possibly more recent openssh" && brew install openssh

brew install gnupg # privacy/encryptation tools

brew install python
ln -si /usr/local/bin/python3 /usr/local/bin/python # create a symlink for python to shadow /usr/bin/python
ln -si /usr/local/bin/pip3 /usr/local/bin/pip # create a symlink to write pip instead of pip3

brew install exa # modern ls replacement
brew install pass # unix like password manager
pip install https://github.com/dylanaraps/pywal/archive/master.zip # pywal

prompt_optinstall "translate-shell" && brew install translate-shell
prompt_optinstall "weechat" && brew install weechat

prompt_optinstall "iterm" && brew install --cask iterm2
prompt_optinstall "anki" && brew install --cask anki
prompt_optinstall "vlc" && brew install --cask vlc
prompt_optinstall "flycut" && brew install --cask flycut
prompt_optinstall "f.lux" && brew install --cask flux
prompt_optinstall "lyricsx" && brew install --cask lyricsx

# Fonts
if prompt_optinstall "the IBM Plex typeface"; then
    brew tap homebrew/cask-fonts;
    brew install --cask font-ibm-plex;
fi;


# Set up Control

echo "To clone the -control- repository, a valid private ssh key is required."
read -r -p "Do you want to load a valid private ssh key? (y/n) "
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Move the ssh private key to ~/keys/sshkey"
    read -r -p "Input any key afterwards... "
    ssh-add ~/keys/sshkey
fi

if [[ ! -d "$HOME/control" ]]
then
    git clone --recursive git@github.com:alt-romes/control.git
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

cd control || exit 1
git pull
./control-setup.sh

# Other
prompt_optinstall "ticker" && brew install achannarasappa/tap/ticker
prompt_optinstall "imagemagick (the default pywal backend)" && brew install imagemagick

if prompt_optinstall "the Haskell Platform"; then
    curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh;
fi;

prompt_optinstall "discord" && brew install --cask discord
prompt_optinstall "steam" && brew install --cask steam

echo "Vielleicht: Things3, Minecraft, Baba Is You, NVIDIA GeForce"

echo "Complete. Restart your session (on iTerm), and run 'wal -i background.png'"
