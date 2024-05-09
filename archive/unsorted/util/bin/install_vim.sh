./configure --prefix=$(brew --prefix) --enable-multibyte --enable-luainterp=yes --with-lua-prefix=$(brew --prefix)/Cellar/lua/5.4.5 --with-tlib=ncurses --with-compiledby=romes --enable-cscope --enable-terminal --disable-gui --without-x
make -j
sudo make install

# failed to compile +lua using --with-luajit
