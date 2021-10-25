#!/usr/bin/env bash
set -e

# ----- --- -----

echo "Installing developer command line tools..."
xcode-select --install

echo "Installing Homebrew..."
if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)";
fi;
brew update

BREW_PREFIX=$(brew --prefix)

echo
echo "Installing latest bash with completion, and setting it as the default shell..."
brew install bash
brew install bash-completion@2

if ! grep -Fq "${BREW_PREFIX}/bin/bash" /etc/shells; then
  # brew_prefix/bin/bash must be in the /etc/shells file to be a valid shell to change to with chsh (`man chsh`)
  echo "${BREW_PREFIX}/bin/bash" | sudo tee -a /etc/shells;
  chsh -s "${BREW_PREFIX}/bin/bash";
fi;

# ----- --- -----

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

# ----- --- -----

echo
echo "Installing tools for control..."
brew install gnupg # privacy/encryptation tools, used to decrypt the private dotfiles

# ----- --- -----

echo
echo "Highly recommended installations..."

echo "1) coreutils and updated tools:"

prompt_optinstall "GNU coreutils" && brew install coreutils

echo "Current git version: $(/usr/bin/git --version)"
prompt_optinstall "a possibly more recent git" && brew install git

echo "Current ssh version: $(/usr/bin/ssh -V)"
prompt_optinstall "a possibly more recent openssh" && brew install openssh

echo "2) recommended terminal programs:"

echo "(WARNING: 'ls' is set as an alias to 'exa' in .bash_profile, either it's installed or the alias is deleted):"
prompt_optinstall "exa (modern ls replacement)" && brew install exa # modern ls replacement, 'ls' is set as an alias for it
prompt_optinstall "pass -- the unix password manager" && brew install pass # unix like password manager
prompt_optinstall "pywal (to set colors according to the wallpaper)" && pip3 install https://github.com/dylanaraps/pywal/archive/master.zip # pywal
prompt_optinstall "translate-shell" && brew install translate-shell
prompt_optinstall "weechat" && brew install weechat
prompt_optinstall "ticker" && brew install achannarasappa/tap/ticker

echo "3) recommended programs:"

prompt_optinstall "iterm" && brew install --cask iterm2
prompt_optinstall "anki" && brew install --cask anki
prompt_optinstall "vlc" && brew install --cask vlc
prompt_optinstall "webtorrent" && brew install --cask webtorrent
prompt_optinstall "flycut" && brew install --cask flycut
prompt_optinstall "f.lux" && brew install --cask flux
prompt_optinstall "lyricsx" && brew install --cask lyricsx

echo "4) recommended fonts:"

if prompt_optinstall "the IBM Plex typeface (used by an iTerm profile)"; then
    brew tap homebrew/cask-fonts;
    brew install --cask font-ibm-plex;
fi;

# TODO: brew install git lfs
brew install git-lfs
git lfs install

# ----- --- -----

if [[ ! -d "$HOME/control" ]]
then
    git clone git@github.com:alt-romes/control.git
fi

cd control || exit 1
git pull

source control-setup.sh # set up `control`

# ----- --- -----

echo
echo "Other recommended instalations..."

prompt_optinstall "imagemagick (the default pywal backend)" && brew install imagemagick

echo "Current vim version: $(/usr/bin/vim --version)"
echo "(WARNING: The following installation might break pywal):"
echo "If it does, run 'brew uninstall vim' to attempt a fix"
prompt_optinstall "a possibly more recent vim (from --HEAD)" && brew install vim --HEAD


echo "Current python version: $(/usr/bin/python3 -V)"
prompt_optinstall "and set up a possibly more recent python" && {
    brew install python
    ln -si /usr/local/bin/python3 /usr/local/bin/python # create a symlink for python to shadow /usr/bin/python
    ln -si /usr/local/bin/pip3 /usr/local/bin/pip # create a symlink to write pip instead of pip3
}
prompt_optinstall "the Haskell Platform" && ( curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh )
prompt_optinstall "rust (and its toolchain)" && ( curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh )
prompt_optinstall "node" && brew install node
prompt_optinstall "go" && brew install go


# ----- --- -----

echo "Suggested for installation:"
echo "brew install --cask discord"
echo "brew install --cask steam"
echo "brew install tldr"
echo "brew install ffmpeg"
echo "brew install youtube-dl"
echo "brew install pandoc"
echo "brew install cheat.sh # internet based cheatsheet"
echo "brew install --cask mactex-no-gui"
echo "brew install --cask font-cozette"
echo "azuki font: http://azukifont.com/font/azuki.html"
echo "brew install gimp"
echo "brew install --cask krita"
echo "brew install balenaetcher"
echo "brew install retroarch # retroarch-metal is the alternative metal graphics API version, however some emulator cores don't support metal."
echo "brew install shellcheck"
echo "mkdir -p ~/.local/bin; curl https://cht.sh/:cht.sh > ~/.local/bin/cht.sh ; chmod +x ~/.local/bin/cht.sh"
echo "XCode from app store; sudo gem install cocoapods"
echo "iMovie from app store"
echo "brew install asciinema"
echo "brew install firefox"
echo "WIP: ... npm install -g asar # required for pywal discord"
echo "brew install --cask emacs"
echo "npm install -g mdanki"
echo "pip install --upgrade jamdict jamdict-data"
echo "brew install sdl2"
echo "brew install csvkit"
echo "brew install openjdk && brew info openjdk # need to symlink"
echo "brew install pcalc" # :D
echo "brew install unar"
echo "Witgui application (to move Wii games)"
echo "brew install --cask nvidia-geforce-now"
echo "brew install z3"
echo "pip install z3-solver"
echo "brew install --cask zoom"
echo "brew install docker"
echo "brew install wireshark"
echo "brew install mpv # to use with https://github.com/pystardust/ani-cli"

echo "Vielleicht: Things3, Minecraft, Baba Is You, NVIDIA GeForce"

# ----- --- -----

echo "TODO Manually"

echo "Set hot corners"
echo "Set LyricsX, F.lux and Flycut to open on login"

# ----- --- -----

echo "Complete. Restart your session (on iTerm)."
