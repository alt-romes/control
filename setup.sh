#!/bin/bash

echo "TODO: make sure files don't exist yet"
cd dotfiles/private && make decrypt

# create dotfiles symlinks
cd $HOME
ln -sf control/dotfiles/public/.bash_profile
ln -sf control/dotfiles/public/.gitconfig
ln -sf control/dotfiles/public/.gitignore_global
ln -sf control/dotfiles/public/.vim/
ln -sf control/dotfiles/public/.iterm/

ln -sf control/dotfiles/private/.ticker.yaml
ln -sf control/dotfiles/private/.ssh
ln -sf control/dotfiles/private/.password-store
echo "TODO: import gpg keys and version control .gnupg"
cd control
# ln -sf control/dotfiles/private/.gnupg

# set romes.initd script to launch on startup
cp launchd/romes.initd.plist ~/Library/LaunchAgents/romes.initd.plist
launchctl load -w ~/Library/LaunchAgents/romes.initd.plist

# development environment set up
xcode-select --install
# install homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
brew update

BREW_PREFIX=$(brew --prefix)

brew install coreutils
brew install bash
brew install bash-completion@2
# set bash v5 as default shell
if ! fgrep -q "${BREW_PREFIX}/bin/bash" /etc/shells; then
  # brew_prefix/bin/bash must be in the /etc/shells file to be a valid shell to change to with chsh (`man chsh`)
  echo "${BREW_PREFIX}/bin/bash" | sudo tee -a /etc/shells;
  chsh -s "${BREW_PREFIX}/bin/bash";
fi;
brew install git
brew install vim --with-override-system-vi
brew install openssh
brew install gnupg # privacy/encryptation tools
brew install pass # pass -- unix like password manager

brew install python

brew install exa # modern ls replacement
pip install https://github.com/dylanaraps/pywal/archive/master.zip # install pywal
brew install translate-shell

brew install --cask iterm2
brew install --cask anki
brew install --cask vlc
brew install --cask flycut
brew install --cask flux
brew install --cask lyricsx
echo "TODO: install and configure weechat"
# brew install weechat
echo "Maybe install: Things3, Minecraft"
