#!/usr/bin/env bash

git clone git@github.com:alt-romes/dotfiles.git mirroringdotdotdot

cd mirroringdotdotdot || exit 1

git filter-repo --subdirectory-filter .vim

git remote add origin git@github.com:alt-romes/.vim.git

git push

cd .. || exit 1

rm -rf mirroringdotdotdot
