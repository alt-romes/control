# romes home configuration
{ config, lib, pkgs, inputs, ... }:
let
  hs-comp = pkgs.haskell.compiler.ghc914;
  hs-pkgs = pkgs.haskell.packages.ghc914;
in
{
  imports = [
    ./codex.nix
    ./ghc.nix
    ./git.nix
    ./vim.nix
    ./email.nix

    # Modules
    ./modules/colors.nix
    ./modules/static_haskell.nix
    ./modules/crush.nix
    ./modules/emacs.nix

    # External modules
    inputs.nix-doom-emacs-unstraightened.homeModule
  ];

  # You can update Home Manager without changing this value.
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "romes";
  home.homeDirectory = if pkgs.stdenv.isLinux then "/home/romes" else "/Users/romes";

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    ripgrep

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

    # Fonts
    maple-mono.NF
    nerd-fonts.symbols-only # emacs uses it
  ];

  fonts.fontconfig.enable = true;

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

  # export STATIC_HASKELL_CABAL_OPTS with cabal options for producing a static binary
  haskell.env.STATIC_HASKELL_CABAL_OPTS = false;

  home.shell.enableZshIntegration = true;
  programs.zsh = {
    enable = true; # will use the same zsh as the one in nixpkgs shared with nix-darwin
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    autosuggestion.enable = true;
    shellAliases = {
      # prefer nix-output-monitor
      nix-shell = "nom-shell";
      nix-build = "nom-build";
    };
    initContent = ''
      # Delete words like bash (up to slash)
      # Very important to usefully do Alt+backspace and friends.
      autoload -U select-word-style
      select-word-style bash
    '';
    localVariables = {
        TYPEWRITTEN_PROMPT_LAYOUT="pure";
    };
    plugins = [
      {
        # will source zsh-autosuggestions.plugin.zsh
        name = "typewritten";
        src = pkgs.fetchFromGitHub {
          owner = "reobin";
          repo = "typewritten";
          rev = "v1.5.2";
          sha256 = "ZHPe7LN8AMr4iW0uq3ZYqFMyP0hSXuSxoaVSz3IKxCc=";
        };
      }
    ];
  };

  programs.ghostty = {
    enable = true;
    # Broken on MacOS, so use the homebrew app. Configuration is still managed here.
    package = if pkgs.stdenv.isLinux then pkgs.ghostty else null;
    enableZshIntegration = true;
    settings = {
        # This fixes the awful problem where the vim colorscheme doesn't extend to the border of the terminal window.
        window-padding-color = "extend";
        unfocused-split-opacity = 1; # don't dim unfocused panes
        # background-opacity = 0.85;
        # background-blur = true;
        font-family = "Maple Mono NF";
    };
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.tmux = {
    enable = true;
    keyMode = "vi";
    mouse = true;
    plugins = [
      pkgs.tmuxPlugins.cpu
    ];
  };

  # Color management
  style.colors.ayu-light.enable = true;
  # style.colors.kanagawa.enable = true;
  # style.colors.gruvbox-light.enable = true;

}
