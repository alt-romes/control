{ lib, pkgs, ... }: {

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
      url."git@gitlab.com:".insteadOf = "https://gitlab.com";
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

}
