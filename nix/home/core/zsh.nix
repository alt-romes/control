
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
        };
        initContent = ''
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
