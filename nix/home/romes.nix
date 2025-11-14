# romes home configuration
{ config, lib, pkgs, inputs, ... }:
let
  hs-comp = pkgs.haskell.compiler.ghc910;
  hs-pkgs = pkgs.haskell.packages.ghc910;
in
{
  imports = [
    ./git.nix
    ./vim.nix
    ../private/ssh.nix
    ../private/kimai.nix

    # Modules
    ./modules/colors.nix
    ./modules/static_haskell.nix
    ./modules/llm_review.nix
  ];

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

    # Haskell
    hs-comp
    hs-pkgs.cabal-install
    hs-pkgs.haskell-language-server
    hs-pkgs.fast-tags

    # Lean
    elan

    nixos-rebuild # to deploy to remote nixos machines directly

    cachix

    # imhex

    # For (building) GHC
    hs-pkgs.alex hs-pkgs.happy autoconf automake python3

    # Make this available by default
    pkgs.pkg-config
  ];

  home.sessionVariables = {
    # Commonly needed in the env for building haskell pkgs
    # ncurses, gmp, zlib
    PKG_CONFIG_PATH = "${pkgs.zlib.dev}/lib/pkgconfig:${pkgs.gmp.dev}/lib/pkgconfig:${pkgs.ncurses.dev}/lib/pkgconfig";
    C_INCLUDE_PATH = "${pkgs.zlib.dev}/include:${pkgs.gmp.dev}/include:${pkgs.ncurses.dev}/include";
    LIBRARY_PATH = "${pkgs.zlib}/lib:${pkgs.gmp}/lib:${pkgs.ncurses}/lib";
  };

  # export STATIC_HASKELL_CABAL_OPTS with cabal options for producing a static binary
  haskell.env.STATIC_HASKELL_CABAL_OPTS = true;

  home.shell.enableZshIntegration = true;
  programs.zsh = {
    enable = true; # will use the same zsh as the one in nixpkgs shared with nix-darwin
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    autosuggestion.enable = true;
    initContent = ''
      # Delete words like bash (up to slash)
      # Very important to usefully do Alt+backspace and friends.
      autoload -U select-word-style
      select-word-style bash

      # GHCUP
      # [ -f ~/.ghcup/env ] && . ~/.ghcup/env
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
    package = null; # Broken on MacOS, so use the homebrew app. Configuration is still managed here.
    enableZshIntegration = true;
    settings = {
        # This fixes the awful problem where the vim colorscheme doesn't extend to the border of the terminal window.
        window-padding-color = "extend";
        unfocused-split-opacity = 1; # don't dim unfocused panes
        # background-opacity = 0.85;
        # background-blur = true;
    };
  };

  #  programs.emacs = {
  #    enable = true;
  #    extraPackages = epkgs: [
  #      epkgs.nix-mode
  #      epkgs.magit
  #    ];
  #  };

  # Color management
  # style.colors.ayu-light.enable = true;
  style.colors.kanagawa.enable = true;
}
