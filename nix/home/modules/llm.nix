{ inputs, ... }:
{
  flake.homeModules.llm = { config, lib, pkgs, ... }:
    let
      aiContext =
        ''
          - When a dependency is not available, use `nix` to temporarily make it available.
            Don't use nix for things which are already available, like the Haskell toolchain.
            (Example: nix-shell -p python3 python3Packages.matplotlib --run 'python3 script.py')
          - Use unqualified imports in Haskell by default. Use qualified imports only when that's the convention or necessary.
          - To browse Haskell dependencies use `cabal repl` to enter a REPL with the project packages.
            To browse a package which is not yet a dependency of the project, use `cabal repl --build-depends=<pkg>`.
            Do not look around with `ghc-pkg` nor directly for interface files
          - Use --no-ext-diff when viewing git diffs
        '';
    in
    {
    
      programs.claude-code = {
        enable = true;
        package = inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        context = aiContext;
        hooks.ghc-session-start = ''
          #!/usr/bin/env bash
          if [ -f "./hadrian/hadrian.cabal" ] && [ -d "./compiler" ]; then
            cat <<'EOF'
          This is a **GHC source tree** (the Glasgow Haskell Compiler).
          - **Typecheck only:** `./hadrian/ghci -j8`
          - **Full build:** one-time configure with `hu build-root init debug --flavour=perf+no_profiled_libs+debug_ghc+debug_info`, then `hu run -d debug --freeze1 -j8`
          - **Investigate a failing test:** build first, then `hu run -d debug -j8 --freeze1 test --only="<test-name>" --keep-test-files -VVV`
          EOF
          fi
        '';
        settings = {
          permissions.defaultMode = "auto";
          effortLevel = "medium";
          tui = "fullscreen";
          theme = "auto";
          skipAutoPermissionPrompt = true;
          model = "opus[1m]";
          hooks.SessionStart =
          [
            {
              hooks = [
                {
                  type = "command";
                  command = "bash ${config.home.homeDirectory}/.claude/hooks/ghc-session-start";
                }
              ];
            }
          ];
        };
      };
    
      programs.codex = {
        enable = true;
        package = inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        context = aiContext;
      };
    };
}
