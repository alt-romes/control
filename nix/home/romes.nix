# romes home configuration
{ config, lib, pkgs, nixvim, ... }:
{
  # You can update Home Manager without changing this value.
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "romes";
  home.homeDirectory = "/Users/romes";

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    fzf ripgrep

    ghc haskell-language-server
    cabal-install
  ];

  programs.nixvim = {
    enable = true;
    viAlias = true;
    vimAlias = true;

    colorschemes.oxocarbon.enable = true;
    # colorschemes.kanagawa.enable = true;
    opts.background = "dark";

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

    keymaps = [
      {
        # Tag jumping
        mode = "n"; key = "<C-j>"; action = "<C-]>";
      }
      {
        # Insert 80 `-` characters to make a line like:
        # --------------------------------------------
        mode = "n"; key = "<leader>-"; action = ":normal 80i-<cr>";
      }
      {
        # Telescope find files
        mode = "n"; key = "<leader>ff"; action = "<cmd>Telescope find_files<cr>";
      }
      {
        # Telescope live grep
        mode = "n"; key = "<leader>fg"; action = "<cmd>Telescope live_grep<cr>";
      }
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
    plugins.web-devicons.enable = true; # required by telescope
    plugins.nvim-surround.enable = true;
    plugins.fugitive.enable = true;
    plugins.emmet.enable = true;

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

  programs.git = {
    enable = true;
    userName = "Rodrigo Mesquita";
    userEmail = "rodrigo.m.mesquita@gmail.com";
    signing.key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ";
    signing.signByDefault = true;

    extraConfig = {
      gpg.format = "ssh";

      push.default = "current";
      pull.default = "origin";
      pull.rebase = true;
      rebase.autosquash = true;

      log.graph = true;
      diff.colorMoved = "default";

      merge.conflictstyle = "zdiff3";
      rerere.enabled = true;

      url."git@github.com:".insteadOf = "https://github.com";
      url."ssh://git@gitlab.com/".insteadOf = "https://gitlab.com";
    } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      "gpg \"ssh\"".program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
    };

    aliases = {
      fixup = "!git log -n 50 --pretty=format:'%h %s' --no-merges | fzf | cut -c -7 | xargs -o git commit --fixup";
    }; 

    delta = {
      enable = true;
      options = {
        navigate = true;
        side-by-side = true;
        light = false;
      };
    };

    # Global ignores
    ignores =
      [ ".DS_Store" "dist-newstyle/" "__pycache__" ".idea" ".vim/undofiles/%*"
        "*.orig" "*.swp" "*.class" "*.aux" "*.log" "*.out" "*.hi" "*.o" "tags" ];
  };

  programs.ghostty = {
    enable = false; # can't enable because this package is broken. We're using the homebrew installed one.
    settings = {
        # Mirror important settings only:
        # This fixes the awful problem where the vim colorscheme doesn't extend to the border of the terminal window.
        window-padding-color = "extend";
    };
  };

  #  programs.emacs = {
  #    enable = true;
  #    extraPackages = epkgs: [
  #      epkgs.nix-mode
  #      epkgs.magit
  #    ];
  #  };
  
  # Broken because plugins write to their own directory on first start
  # (also, undofiles can't be written to .vim)
  # Let's try going to NixVim route
  # home.file = {
  #   ".vim".source = pkgs.fetchFromGitHub {
  #     fetchSubmodules = true;
  #     owner = "alt-romes";
  #     repo = ".vim";
  #     rev = "master";
  #     sha256 = "sha256-l5PjVUck7jHu6SYazJsvbPOtneM9+U7WNpfutpYcJfA=";
  #   };
  # };
}
