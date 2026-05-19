# romes home configuration
{ self, inputs, ... }:
{
  flake.homeModules.romes = { pkgs, ... }:
    let
      hs-comp = pkgs.haskell.compiler.ghc914;
      hs-pkgs = pkgs.haskell.packages.ghc914;
    in
    {
      imports = [
        # Private
        self.homeModules.ssh
        self.homeModules.kimai

        # Core
        self.homeModules.vim
        self.homeModules.git
        self.homeModules.zsh

        # More
        self.homeModules.ghc
        self.homeModules.llm
        self.homeModules.emacs
        self.homeModules.email
        self.homeModules.colors
        self.homeModules.fonts
        self.homeModules.static_haskell
      ];

      # --------------------------------------------------------------------------------
      # My modules

      # style.colors.theme = "melange-light";
      style.colors.theme = "rose-pine-dawn";
      # Other options: oxocarbon, ayu-light, ayu-dark, everforest, hotblue,
      # github, kanagawa, gruvbox-light, gruvbox-dark, catppuccin, tokyonight,
      # rose-pine, nord, catppuccin-latte, rose-pine-dawn, tokyonight-day,
      # everforest-light, github-light-high-contrast, kanagawa-lotus, dayfox,
      # dawnfox, melange-light, modus-operandi, gruvbox-material-light,
      # nord-light

      style.fonts.font = "martian-mono";
      # Other options: ioskeley, iosevka, maple-mono, jetbrains-mono,
      # fira-code, cascadia-code, victor-mono, hack, commit-mono, geist-mono,
      # zed-mono, departure-mono, monaspace-neon, monaspace-argon,
      # monaspace-krypton, monaspace-xenon, monaspace-radon, intel-one-mono,
      # recursive-mono, martian-mono, mononoki, fantasque-sans-mono, lilex

      programs.kimai.enable = true;

      haskell.env.STATIC_HASKELL_CABAL_OPTS = false; # cabal build $(echo $STATIC_HASKELL_CABAL_OPTS)

      # --------------------------------------------------------------------------------
      # Packages / programs

      home.packages = with pkgs; [
        ripgrep
        eza

        # Haskell
        hs-comp
        cabal-install
        haskell-language-server
        haskellPackages.fast-tags
        haskellPackages.hoogle

        nix-output-monitor

        # nixos-rebuild # to deploy to remote nixos machines directly
        nixos-rebuild-ng # better version?

        gh # github cli

        # imhex

        # For (building) GHC
        alex happy autoconf automake

        (python3.withPackages(ps: [ps.jupyter]))
          # required by GHC and org +jupyter

        # Make this available by default
        pkgs.pkg-config
        pkgs.zlib pkgs.zlib.dev
        pkgs.gmp pkgs.gmp.dev
        pkgs.ncurses pkgs.ncurses.dev

        # Fonts
        nerd-fonts.symbols-only # emacs uses it
      ];
      fonts.fontconfig.enable = true;

      programs.ghostty = {
        enable = true;
        # Broken on MacOS, so use the homebrew app. Configuration is still managed here.
        package = null;
        enableZshIntegration = true;
        settings = {
            # This fixes the awful problem where the vim colorscheme doesn't extend to the border of the terminal window.
            window-padding-color = "extend";

            unfocused-split-opacity = 0.95; # don't dim unfocused panes
            # background-opacity = 0.95;
            # background-blur = true;
        };
      };

      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
      };

      programs.tmux = {
        enable = true;
        focusEvents = true;
        keyMode = "vi";
        escapeTime = 0;
        mouse = true;
        plugins = [
          pkgs.tmuxPlugins.extrakto
        ];
        extraConfig = ''
          set -g history-limit 50000
          set -g default-terminal "tmux-256color"

          # Emacs key bindings in tmux command prompt (prefix + :) are better than
          # vi keys, even for vim users
          set -g status-keys emacs

          bind C-h select-pane -L
          bind h   select-pane -L
          bind C-l select-pane -R
          bind l   select-pane -R
          bind C-k select-pane -U
          bind k   select-pane -U
          bind C-j select-pane -D
          bind j   select-pane -D

          # For shift+enter
          set -g allow-passthrough on
          set -s extended-keys on
          set -as terminal-features 'xterm*:extkeys'
          set -as terminal-features 'xterm*:RGB'

        '';
      };

      # --------------------------------------------------------------------------------
      # Home

      # Home Manager needs a bit of information about you and the
      # paths it should manage.
      home.username = "romes";
      home.homeDirectory = if pkgs.stdenv.isLinux then "/home/romes" else "/Users/romes";

      home.sessionVariables = {
        # Commonly needed in the env for building haskell pkgs
        # ncurses, gmp, zlib
        PKG_CONFIG_PATH = "${pkgs.zlib.dev}/lib/pkgconfig:${pkgs.gmp.dev}/lib/pkgconfig:${pkgs.ncurses.dev}/lib/pkgconfig";
        C_INCLUDE_PATH = "${pkgs.zlib.dev}/include:${pkgs.gmp.dev}/include:${pkgs.ncurses.dev}/include";
        LIBRARY_PATH = "${pkgs.zlib}/lib:${pkgs.gmp}/lib:${pkgs.ncurses}/lib";
        LD_LIBRARY_PATH = "${pkgs.zlib}/lib:${pkgs.gmp}/lib:${pkgs.ncurses}/lib";
      };

      home.sessionPath = [
        "$HOME/.local/bin"
      ];

      home.shell.enableZshIntegration = true;

      # --------------------------------------------------------------------------------
      # Meta

      # You can update Home Manager without changing this value.
      home.stateVersion = "24.11";

      # Let Home Manager install and manage itself.
      programs.home-manager.enable = true;

    };

}
