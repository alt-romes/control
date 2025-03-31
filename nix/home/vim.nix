{ config, lib, pkgs, nixvim, ... }:
{

  programs.nixvim = {
    enable = true;
    viAlias = true;
    vimAlias = true;

    colorschemes.ayu.enable = true;
    # colorschemes.oxocarbon.enable = true;
    # colorschemes.kanagawa.enable = true;
    opts.background = "light";

    opts = {
      # Options from https://github.com/alt-romes/.vim
      number=true; relativenumber=true;               # Set relative numbered lines
      expandtab=true; tabstop=4; shiftwidth=4;        # Indent by 4 spaces
      hlsearch=true; ignorecase=true; incsearch=true; # Highlight case-insensitive search while typing
      wildmenu=true;                                  # Display command-line completion menu
      mouse="a";                                      # Enable all mouse modes
      wrap=false; sidescroll=12; sidescrolloff=4;     # Disable line wrapping and set smoother horizontal scroll
      autoread=true;                                  # Automatically re-read files changed outside if not changed inside 
      modeline=true; modelines=4;                     # Check first and last file lines for modelines (that :set options)
      exrc=true; secure=true;                         # Read current directory .vimrc (with security-related limitations)
      spelllang="en_gb";                              # Spell languages to use when spell checking (:set spell)
      regexpengine=0;                                 # Automatically select regexp engine
      undofile=true; undodir="/Users/romes/.undofiles.vim";  # Persistent undo (:h persistent-undo)
      backspace="indent,eol,start";                   # Make backspace work as expected
      # set path+=** ??
      foldenable=false; foldmethod="marker";          # Fold with markers (e.g. set in a modeline to marker), open by default
      # termguicolors=true;
      # clipboard^=unnamed ??
      conceallevel=2;                                 # Conceal level to hide typesetting details
      smartcase=true;                                 # Will use case-sensitive if capital or \C letter is present
      smarttab=true;                                  # Makes tabbing smarter will realize you have 2 vs 4, and default to tabstop/tabwidth when not obvious
      cursorline=true; cursorlineopt="both";          # Highlight the line number of the cursor line (cursorlineopt=number is also good)
      swapfile=true;                                  # We want swapfiles, and use vim's macOS default 'directory' option, which is within ~/Library
    };

    files."ftplugin/nix.lua".opts = {
        tabstop=2; shiftwidth=2;
    };

    keymaps = [
      { # Tag jumping
        mode = "n"; key = "<C-j>"; action = "<C-]>"; }
      { # Insert 80 `-` characters to make a line like:
        # --------------------------------------------
        mode = "n"; key = "<leader>-"; action = ":normal 80i-<cr>"; }
      { # Telescope find files
        mode = "n"; key = "<leader>f"; action = "<cmd>Telescope find_files<cr>"; }
      { # Telescope live grep
        mode = "n"; key = "<leader>g"; action = "<cmd>Telescope live_grep<cr>"; }
      { # Nvim-tree open
        mode = "n"; key = "<leader>t"; action = "<cmd>NvimTreeOpen<cr>"; }
    ];

    /* Language Server Protocols */
    plugins.lsp = {
        enable = true;
        servers.hls = {
          enable = true;
          installGhc = false; # Disable a warning for ghc installation
        };
    };

    /* Plugins */
    plugins.treesitter.enable = true;
    plugins.telescope.enable = true;
    plugins.telescope.extensions.fzf-native.enable = true;
    plugins.web-devicons.enable = true; # required by telescope
    plugins.nvim-surround.enable = true;
    plugins.fugitive.enable = true;
    plugins.emmet.enable = true;

    plugins.nvim-tree = {
      enable = true;
      disableNetrw = true;
      openOnSetup = true;
    };

    /* DAP */
    plugins.dap = {
      enable = true;
    };

    extraPlugins = [(pkgs.vimUtils.buildVimPlugin {
        name = "linediff.vim";
        src = pkgs.fetchFromGitHub {
            owner = "AndrewRadev";
            repo = "linediff.vim";
            rev = "ddae71ef5f94775d101c1c70032ebe8799f32745";
            hash = "sha256-ZyQzLpzvS887J1Gdxv1edC9MhPj1EEITh27rUPuFugU=";
        };
    })];
  };

}
