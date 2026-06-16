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
        skills.failing-tests-to-tmux = ''
          ---
          name: failing-tests-to-tmux
          description: Open one tmux window per failing GHC test, each in its kept .run dir with the repro command pre-typed. Use when asked to open tmux windows for failing tests from a `hu run ... test --only=...` run.
          ---

          # Failing GHC tests -> one tmux window each

          1. Re-run only the failing tests, keeping work dirs and printing invocations:
             `hu run -d <root> -j8 --freeze1 test --only="<failing tests>" -VVV --keep-test-files > /tmp/ft.log 2>&1`
             (same `-d <root>` the user used).

          2. From the log: the in-tree compiler is `grep -o 'compiler="[^"]*"' /tmp/ft.log | head -1`.
             Each test prints `=====> <name>(<way>) ...` then a `cd "<.run dir>" && <command> < ...`
             line (the dir has literal spaces). The `.run` dir is the window cwd; `<command>` is the
             repro -- drop the trailing ` < ...` and any diff text on that line.

          3. Per command: direct `ghc` invocations use verbatim. Makefile tests (`$MAKE`) become
             `make ... TEST_HC=<in-tree compiler>` -- without TEST_HC a bare `make` uses the system
             ghc on $PATH and won't reproduce the failure.

          4. Open one detached window per test, cwd in its `.run` dir, command pre-typed (no Enter):
             ```bash
             S=$(tmux display-message -p '#S')
             mk() {  # name  dir  cmd
               tmux new-window -d -t "$S:" -n "$1" -c "$2"   # trailing colon targets the session, not window index
               tmux send-keys -t "$S:$1" -l "$3"            # -l literal, no Enter
             }
             ```
             Wrap each path/command as one single-quoted bash arg (paths have spaces; package
             commands embed double but no single quotes).

          5. Report a table: window, `.run` dir, command, failure reason.
        '';
        hooks.ghc-session-start = ''
          #!/usr/bin/env bash
          if [ -f "./hadrian/hadrian.cabal" ] && [ -d "./compiler" ]; then
            cat <<'EOF'
          This is a **GHC source tree** (the Glasgow Haskell Compiler).
          - **Typecheck only:** `./hadrian/ghci -j8`
          - **Full build:** one-time configure with `hu build-root init debug --flavour=perf+no_profiled_libs+debug_ghc+debug_info`, then `hu run -d debug --freeze1 -j8`
          - **Investigate a failing test:** build first, then `hu run -d debug -j8 --freeze1 test --only="<test-name>" --keep-test-files -VVV`
          If you're given commands using a different build-root, use it instead of `debug`
          - **Look up GHC issues/MRs:** `ghc-index preview issue|mr <N>` renders a gitlab.haskell.org ghc/ghc ticket as Markdown (prefer over WebFetch); `ghc-index sync` refreshes the local index if stale.
          EOF
          fi
        '';
        hooks.control-nix-session-start = ''
          #!/usr/bin/env bash
          case "$PWD" in
            "$HOME"/control|"$HOME"/control/*)
              cat <<'EOF'
          This is the system and home nix configuration repository.
          - To run nix derivations in-tree you must append `?submodules=1` to the flake reference
            (e.g. `nix run '/Users/romes/control/.?submodules=1#foo'`), otherwise submodules are
            not included and the build will fail.
          EOF
              ;;
          esac
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
                {
                  type = "command";
                  command = "bash ${config.home.homeDirectory}/.claude/hooks/control-nix-session-start";
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
