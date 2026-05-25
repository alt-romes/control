{
  flake.homeModules.zsh = { pkgs, ... }:
    {
      programs.zsh = {
        enable = true; # will use the same zsh as the one in nixpkgs shared with nix-darwin
        enableCompletion = true;
        syntaxHighlighting.enable = true;
        autosuggestion.enable = true;
        shellAliases = {
          g = "git";

          mv = "mv -i";
          cp = "cp -i";
          ls = "eza";

          httpserver = "nix-shell -p python3 --run 'python -m http.server 25565'";

          # prefer nix-output-monitor
          nix-shell = "nom-shell";
          nix-build = "nom-build";

          ghc-shell = "nix-shell -p haskell.compiler.ghc914 haskellPackages.alex haskellPackages.happy autoconf automake python3 gmp zlib ncurses";

          run-linux-vm = ''
            IP_FILE=/Users/romes/control/vms/fukusuke/ip
            if [ -e "$IP_FILE" ]; then
              PREV_MTIME=$(stat -f %m "$IP_FILE")
            else
              PREV_MTIME=0
            fi

            ${pkgs.tmux}/bin/tmux new -s microvm -d
            ${pkgs.tmux}/bin/tmux new-window -t microvm: -n vm-console "exec nix run '/Users/romes/control/.?submodules=1#fukusuke-vm'"

            echo "The VM is now running in a tmux session:"
            echo "  tmux attach -t microvm                "

            echo "Waiting for VM to update IP at $IP_FILE..."
            while true; do
              if [ -e "$IP_FILE" ]; then
                MTIME=$(stat -f %m "$IP_FILE")
                  if [ "$MTIME" -gt "$PREV_MTIME" ]; then
                    break
                  fi
              fi
              sleep 0.2
            done

            echo "Connect to VM with agent forwarding (-A):"
            echo "  ssh -A $(cat $IP_FILE)"
          '';

        };

        initContent = ''
          # Force emacs keymap. Otherwise, when $EDITOR contains "vi" (e.g. "vim"
          # as set system-wide on the fukusuke VM), zsh picks the vi keymap and
          # ^A/^E etc. end up bound to self-insert.
          bindkey -e

          # Delete words like bash (up to slash)
          # Very important to usefully do Alt+backspace and friends.
          autoload -U select-word-style
          select-word-style bash
        '';

        localVariables = {
            TYPEWRITTEN_PROMPT_LAYOUT = if pkgs.stdenv.isLinux then "singleline_verbose" else "singleline";
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
    };
}
