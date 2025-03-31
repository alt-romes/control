# romes home configuration
{ config, lib, pkgs, nixvim, ... }:
let
  hs-comp = pkgs.haskell.compiler.ghc910;
  hs-pkgs = pkgs.haskell.packages.ghc910;
in
{
  imports = [
    ./git.nix
    ./vim.nix
    ../private/ssh.nix
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

    zlib # needed a lot

    colmena       # deployment tool
    nixos-rebuild # to deploy to remote nixos machines directly

    imhex
  ];

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
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
    enable = false; # can't enable because this package is broken. We're using the homebrew installed one.
    settings = {
        theme = "oxocarbon";
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
}
