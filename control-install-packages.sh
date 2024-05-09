#!/bin/bash

brew install iterm
brew install anki

brew install llvm
brew install ffmpeg
brew install --cask mactex-no-gui

echo "Install Vulkan (you likely need the SDK from the homepage rather than anything from brew)"
# brew install molten-vk
# brew install vulkan-headers

brew install --cask obs
brew install --cask blender
brew install --cask discord
brew install --cask element
brew install --cask firefox
brew install --cask emacs
brew install --cask steam
brew install --cask nvidia-geforce-now

# Fonts
echo "Iosevka"
echo "IBM Plex"
# Victor Mono
brew install --cask font-victor-mono

echo "App Store Apps:"

echo "Things3"
echo "Logic Pro"
echo "Final Cut Pro"
echo "Sketchbook Pro"
echo "XCode"


echo "Other Apps and Programs:"

echo "Aseprite"

echo "On GHCUP, enable pre-releases and optionally install a x86_64-apple-darwin on aarch64-apple-darwin to be able to cross compile to Intel-based macs"
echo "ghcup config add-release-channel https://raw.githubusercontent.com/haskell/ghcup-metadata/master/ghcup-prereleases-0.0.7.yaml"
echo "ghcup install ghc -u 'https://downloads.haskell.org/ghc/9.4.4/ghc-9.4.4-x86_64-apple-darwin.tar.xz' x86_64-apple-darwin-9.4.4"

