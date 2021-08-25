#!/bin/bash

echo "TODO: make sure files don't exist yet"
cd dotfiles/private && make decrypt

# must have programs
echo "Programs to install:"
echo "exa"
echo "pywal (latest version -- pip install https://github.com/dylanaraps/pywal/archive/master.zip)"
