{ ghcVersion, ... }:
{
  flake.homeModules.zsh = { config, pkgs, ... }:
    {
      programs.zsh = {
        enable = true; # will use the same zsh as the one in nixpkgs shared with nix-darwin
        enableCompletion = true;
        syntaxHighlighting.enable = true;
        autosuggestion.enable = true;

        initContent = ''
          # Force emacs keymap. Otherwise, when $EDITOR contains "vi" (e.g. "vim"
          # as set system-wide on the fukusuke VM), zsh picks the vi keymap and
          # ^A/^E etc. end up bound to self-insert.
          bindkey -e

          # Delete words like bash (up to slash)
          # Very important to usefully do Alt+backspace and friends.
          autoload -U select-word-style
          select-word-style bash

          # Build and launch the fukusuke Linux microVM.
          #
          # The build runs in the FOREGROUND so its (often long and
          # error-prone) nix output is visible -- if evaluation or the build
          # fails, you see exactly why and we bail out instead of hanging.
          # Only the actual VM run is sent to a detached tmux window; since the
          # runner is already built by then, `nix run` starts instantly.
          run-linux-vm() {
            local flake='/Users/romes/control/.?submodules=1#fukusuke-vm'
            local ip_file=/Users/romes/control/vms/fukusuke/ip

            local prev_mtime=0
            [ -e "$ip_file" ] && prev_mtime=$(stat -f %m "$ip_file")

            echo "==> Building VM runner (nix output below)..."
            if ! nom build "$flake" --no-link; then
              echo "==> VM build FAILED -- see the nix output above." >&2
              return 1
            fi

            echo "==> Build OK. Launching VM in tmux session 'microvm'..."
            ${pkgs.tmux}/bin/tmux new -s microvm -d 2>/dev/null
            ${pkgs.tmux}/bin/tmux new-window -t microvm: -n vm-console "exec nix run '$flake'"

            echo "    Attach to the console with: tmux attach -t microvm"

            echo "==> Waiting for VM to update IP at $ip_file..."
            local waited=0
            while true; do
              if [ -e "$ip_file" ]; then
                local mtime=$(stat -f %m "$ip_file")
                [ "$mtime" -gt "$prev_mtime" ] && break
              fi
              sleep 0.2
              waited=$((waited + 1))
              if [ "$waited" -ge 600 ]; then
                echo "==> Timed out (120s) waiting for the VM IP." >&2
                echo "    The VM likely failed to boot -- inspect the console:" >&2
                echo "      tmux attach -t microvm" >&2
                return 1
              fi
            done

            echo "==> VM is up. Connect with agent forwarding (-A):"
            echo "  ssh -A $(cat "$ip_file")"
          }
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

      # Also configure bash so aliases are available in bash-based shells
      # (notably `nix-shell`, whose generated rcfile sources ~/.bashrc).
      programs.bash = {
        enable = true;
        enableCompletion = true;
      };

      # Shell-agnostic aliases: home-manager emits these into every enabled
      # shell (zsh AND bash), so a single definition works in `nix-shell` too.
      home.shellAliases = {
        g = "git";

        # Local fzf index of GHC's GitLab issues/MRs. The preview --style
        # follows the active color theme's background (see home/modules/colors.nix).
        # --repo points at a local clone so ctrl-d opens a vim Fugitive diff of an MR.
        ghc-index = "gitlab-index --project ghc/ghc --style ${config.style.colors.background} --repo ${config.home.homeDirectory}/ghc-dev/ghc";

        ".." = "cd ../";
        "..." = "cd ../..";

        mv = "mv -i";
        cp = "cp -i";
        ls = "eza";

        httpserver = "nix-shell -p python3 --run 'python -m http.server 25565'";

        # prefer nix-output-monitor
        nix-shell = "nom-shell";
        nix-build = "nom-build";

        ghc-shell = "nix-shell -p haskell.compiler.${ghcVersion} haskellPackages.alex haskellPackages.happy autoconf automake python3 gmp zlib ncurses";
      };
    };
}
