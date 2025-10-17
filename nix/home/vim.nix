{ config, lib, pkgs, inputs, ... }:
{

  imports = [ inputs.nixvim.homeModules.nixvim ];

  programs.nixvim = {
    # use nixvim pkgs == home-manager pkgs == nixos nixpkgs
    # Not always a win since we may diverge from what is tested upstream and
    # run into new issues, but allows us to re-use the same pkgs (more
    # consistent) and share configs like allowUnfree. See
    # https://github.com/nix-community/nixvim/issues/2147
    nixpkgs.useGlobalPackages = true;

    enable = true;
    viAlias = true;
    vimAlias = true;

    # Color management done via the colors module in romes.nix

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
      conceallevel=2;                                 # Conceal level to hide typesetting details
      smartcase=true;                                 # Will use case-sensitive if capital or \C letter is present
      smarttab=true;                                  # Makes tabbing smarter will realize you have 2 vs 4, and default to tabstop/tabwidth when not obvious
      cursorline=true; cursorlineopt="both";          # Highlight the line number of the cursor line (cursorlineopt=number is also good)
      swapfile=true;                                  # We want swapfiles, and use vim's macOS default 'directory' option, which is within ~/Library
    };

    # Share clipboard between vim and system
    clipboard.register = "unnamedplus";

    files."ftplugin/nix.lua".opts = {
        tabstop=2; shiftwidth=2;
    };

    files."ftplugin/haskell.lua".opts = {
        tabstop=2; shiftwidth=2;
    };

    keymaps = [
      { # Tag jumping
        mode = "n"; key = "<C-j>"; action = "<C-]>"; }
      { # Insert 80 `-` characters to make a line like:
        # --------------------------------------------
        mode = "n"; key = "<leader>-"; action = ":normal 80i-<cr>"; }
      # Use fzf-lua for finding and grepping. Much faster.
      # { # Telescope find files
      #   mode = "n"; key = "<leader>f"; action = "<cmd>Telescope find_files<cr>"; }
      # { # Telescope live grep
      #   mode = "n"; key = "<leader>g"; action = "<cmd>Telescope live_grep<cr>"; }
      # Use Telescope for its plugins like Hoogle and Manix
      { # Telescope Hoogle
        mode = "n"; key = "<leader>h"; action = "<cmd>Telescope hoogle<cr>"; }
      { # Telescope Manix
        mode = "n"; key = "<leader>m"; action = "<cmd>Telescope manix<cr>"; }
      { # Nvim-tree open
        mode = "n"; key = "<leader>t"; action = "<cmd>NvimTreeOpen<cr>"; }
      { # Nvim-lsp code action
        mode = "n"; key = "<leader>a"; action = "<cmd>lua vim.lsp.buf.code_action()<cr>"; }
      { # Nvim-lsp jump to definition
        mode = "n"; key = "gd"; action = "<cmd>lua vim.lsp.buf.definition()<cr>"; }
      { # Open file selector in the directory of the current file
        mode = "n"; key = "<leader>o"; action = "<cmd>lua require(\"nvim-tree.api\").tree.open({ path = vim.fn.expand('%:p:h'), find_file = true })<cr>"; }
    ];

    /* Language Server Protocols */
    plugins.lsp = {
        enable = true;
        servers = {
          # Haskell
          hls = {
            enable = true;
            installGhc = false; # Disable a warning for ghc installation
          };

          # Nix
          nixd.enable = true;

          # Swift
          sourcekit.enable = true;
        };
    };

    /* Plugins */
    plugins.treesitter.enable = true;

    # Telescope is too slow to find files, so we use fzf-lua there.
    # However, telescope has the manix and hoogle plugins.
    # We use it for those searches only
    plugins.telescope.enable = true;
    plugins.telescope.extensions.fzf-native.enable = true;
    plugins.telescope.extensions.manix.enable = true; dependencies.manix.enable = true;
    plugins.fzf-lua.enable = true;
    plugins.fzf-lua.keymaps = {
      "<leader>f" = "files";
      "<leader>g" = "live_grep";
      "<leader>b" = "builtin";
    };
    plugins.fzf-lua.settings.winopts.backdrop = 100;
    plugins.fzf-lua.settings.winopts.fullscreen = true;
    plugins.web-devicons.enable = true; # required by telescope

    plugins.nvim-surround.enable = true;
    plugins.fugitive.enable = true;
    plugins.emmet.enable = true;

    plugins.nvim-tree = {
      enable = true;
      settings = { disable_netrw = true; };
      openOnSetup = true;
    };

    /* DAP */
    plugins.dap = {
      enable = true;

      adapters.servers = {
        haskell = {
          id = "haskell-debugger";
          port = "\${port}";

          # Launch this server automatically for each launch
          executable = {
            command = "hdb";
            args = ["server" "--port" "\${port}"];
          };
        };
      };

      configurations = {
        haskell = [
          {
            type = "haskell-debugger";
            request = "launch";
            name = "hdb:launch";
            # projectRoot = "\${workspaceFolder}";
            # entryFile = "\${file}";
            # entryPoint = "main";
            # entryArgs = [
            #   "" # without this entryArgs is gone?
            # ];
            # extraGhcArgs = [
            # ];
          }
        ];
      };

    };

    plugins.copilot-vim = {
      enable = true; # experimenting...

      settings = {
        enabled = false; # disabled by default. Use :Copilot enable
        filetypes = {
          # "*" = false;
          # python = true;
        };
      };
    };

    # Lean
    plugins.lean = {
      enable = true;
    };

    /* Extra Plugins */
    extraPlugins = [
      (pkgs.vimUtils.buildVimPlugin {
        name = "linediff.vim";
        src = pkgs.fetchFromGitHub {
            owner = "AndrewRadev";
            repo = "linediff.vim";
            rev = "ddae71ef5f94775d101c1c70032ebe8799f32745";
            hash = "sha256-ZyQzLpzvS887J1Gdxv1edC9MhPj1EEITh27rUPuFugU=";
        };
      })

      pkgs.vimPlugins.telescope_hoogle
    ];

    # Custom extra telescope extensions
    plugins.telescope.enabledExtensions = [ "hoogle" ];

    extraPackages = [ pkgs.haskellPackages.hoogle ]; # for telescope hoogle
  };

}
