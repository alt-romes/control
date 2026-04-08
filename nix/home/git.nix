{ lib, pkgs, ... }: {

  programs.git = {
    enable = true;
    signing.key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ";
    signing.signByDefault = true;

    settings = {
      user.name = "Rodrigo Mesquita";
      user.email = "rodrigo.m.mesquita@gmail.com";

      gpg.format = "ssh";

      push.default = "current";
      pull.default = "origin";
      pull.rebase = true;
      rebase.autosquash = true;

      log.graph = true;
      diff.colorMoved = "default";

      merge.conflictstyle = "zdiff3";
      rerere.enabled = true;

      commit.verbose = true; # show diff below message on "git commit"

      url."git@github.com:".insteadOf = "https://github.com";
      url."git@gitlab.com:".insteadOf = "https://gitlab.com";

      alias.fixup = "!git log -n 50 --pretty=format:'%h %s' --no-merges | fzf | cut -c -7 | xargs -o git commit --fixup";

      # Repository inspection commands adapted from:
      # https://piechowski.io/post/git-commands-before-reading-code/
      # What Changes the Most
      alias.churn = "!git log --format=format: --name-only --since=\"1 year ago\" | sort | uniq -c | sort -nr | head -20";
      # Who Built This
      alias.authors = "!git shortlog -sn --no-merges";
      # Where Do Bugs Cluster
      alias.bughotspots = "!git log -i -E --grep=\"fix|bug|broken\" --name-only --format='' | sort | uniq -c | sort -nr | head -20";
      # Is This Project Accelerating or Dying
      alias.velocity = "!git log --format='%ad' --date=format:'%Y-%m' | sort | uniq -c";
      # How Often Is the Team Firefighting
      alias.firefighting = "!git log --oneline --since=\"1 year ago\" | grep -iE 'revert|hotfix|emergency|rollback'";
    } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      "gpg \"ssh\"".program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
    };

    # Global ignores
    ignores =
      [ ".DS_Store" "dist-newstyle/" "__pycache__" ".idea" ".vim/undofiles/%*"
        "*.orig" "*.swp" "*.class" "*.aux" "*.log" "*.out" "*.hi" "*.o" "tags" ];
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      side-by-side = true;
      light = false;
    };
  };

}
