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

    hs-comp
    hs-pkgs.cabal-install
    hs-pkgs.haskell-language-server
    haskellPackages.fast-tags

    nixos-rebuild # to deploy to remote nixos machines directly

    imhex

    # For (building) GHC
    hs-pkgs.alex hs-pkgs.happy autoconf automake python3
  ];

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

  # Color management
  style.colors.oxocarbon.enable = true;
  # style.colors.base16.enable = true;
  # style.colors.base16.colorScheme = inputs.nix-colors.colorSchemes.rose-pine-dawn;

  # programs.nixvim.colorschemes.base16.enable = true;
  # programs.nixvim.colorschemes.base16.colorscheme =
  #     lib.mapAttrs (_: color: "#${color}")
  #       inputs.nix-colors.colorSchemes.rose-pine-dawn.palette;

  programs.ghostty = {
    enable = true;
    package = null; # Broken on MacOS, so use the homebrew app. Configuration is still managed here.
    enableZshIntegration = true;
    settings = {
        # Theme is managed by colors.nix

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
}
