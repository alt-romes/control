# romes home configuration
{ config, lib, pkgs, ... }:
{
  # You can update Home Manager without changing this value.
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # imports = lib.mkIf pkgs.stdenv.isDarwin [ ./darwin/romes.nix ];

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "romes";
  home.homeDirectory = "/Users/romes";

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [ fzf ];

#  programs.emacs = {
#    enable = true;
#    extraPackages = epkgs: [
#      epkgs.nix-mode
#      epkgs.magit
#    ];
#  };

  programs.git = {
    userName = "Rodrigo Mesquita";
    userEmail = "rodrigo.m.mesquita@gmail.com";
    signing.key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ";

    extraConfig = {
      gpg.format = "ssh";
      commit.gpgsign = true;

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
    };

    aliases = {
      fixup = "!git log -n 50 --pretty=format:'%h %s' --no-merges | fzf | cut -c -7 | xargs -o git commit --fixup"
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
}
