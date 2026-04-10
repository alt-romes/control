{ config, lib, ... }:
{
  options = {
    programs.custom.doom-emacs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable my Doom Emacs config.";
    };
  };

  config = {

    programs.emacs = {
      enable = false; # doom-emacs instead
      extraPackages = epkgs: with epkgs; [
        magit # Git
        org   # Orgmode
        evil  # Vi
      ];
      extraConfig = ''
       ;; Org mode
       (global-set-key (kbd "C-c l") #'org-store-link)
       (global-set-key (kbd "C-c a") #'org-agenda)
       (global-set-key (kbd "C-c c") #'org-capture)

       ;; Evil mode (vim keybindings)
       (require 'evil)
       (evil-mode 1)
      '';
    };

    programs.doom-emacs = {
      enable = config.programs.custom.doom-emacs;
      doomDir = ./doom.d;
      extraPackages = epkgs: [
        epkgs.treesit-grammars.with-all-grammars
      ];
    };

  };
}
