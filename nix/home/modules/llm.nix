{ inputs, ... }:
{
  flake.homeModules.llm = { config, pkgs, ... }:
    let
      globalContext =
        ''
          - Always prefer short and obviously correct code. If you can trade
            off perfect compliance for simplicity, propose it.
          - Do not add useless comments comparing the new code to how it worked
            previously. The code should speak for itself always. Only use
            comments in exceptional cases that need clarifying, and make them
            short and straight to the point. Write no comments at all otherwise.
          - When a dependency is not available, use `nix` to temporarily make it available.
            Don't use nix for things which are already available, like the Haskell toolchain.
            (Example: nix-shell -p python3 python3Packages.matplotlib --run 'python3 script.py')
          - Use unqualified imports in Haskell by default. Use qualified imports only when that's the convention or necessary.
          - To browse Haskell dependencies use `cabal repl` to enter a REPL with the project packages.
            To browse a package which is not yet a dependency of the project, use `cabal repl --build-depends=<pkg>`.
            Do not look around with `ghc-pkg` nor directly for interface files
          - Use --no-ext-diff when viewing git diffs; use --no-gpg-sign to
            commit; prefer using my own words adapted from the prompt as the
            commit message, only expand with more when really necessary
          - When editing a Haskell module, read the entire module before the
            edit. All changes should fit in the module holistically, rather than
            being `sed`ed in without consideration for the context in which the
            edit is being done relative to the rest of the module contents.
        '';

      taTaskrc = pkgs.writeText "ta-taskrc" ''
        hooks=off
        confirmation=off
        verbose=new-uuid,affected,label
        uda.origin.type=string
        uda.origin.label=Origin
        uda.owner.type=string
        uda.owner.label=Owner
        report.board.description=Pending agent tasks
        report.board.columns=uuid.short,start.active,owner,project,depends,tags,description.count
        report.board.labels=UUID,A,Owner,Project,Deps,Tags,Description
        report.board.filter=status:pending
        report.board.sort=project+,entry+
      '';

      ta = pkgs.writeShellApplication {
        name = "ta";
        runtimeInputs = [ pkgs.flock ];
        text = ''
          export TASKDATA="''${TA_DATA:-$HOME/.local/share/agent-tasks}" TASKRC=${taTaskrc}
          mkdir -p "$TASKDATA"
          # Ensure no races on `task start` to claim (this command
          # specifically would allow racing agents to start the same task)
          exec flock "$TASKDATA/lock" task "$@"
        '';
      };
    in
    {
      home.packages = [ ta ];

      programs.claude-code = {
        enable = true;
        package = inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        context = globalContext;

        hooks.ghc-session-start = ''
          #!/usr/bin/env bash
          if [ -f "./hadrian/hadrian.cabal" ] && [ -d "./compiler" ]; then
            cat <<'EOF'
          This is a GHC source tree (the Glasgow Haskell Compiler).
          - Typecheck only: `./hadrian/ghci -j8`
          - Full build: one-time configure with
              `hu build-root init debug --flavour=perf+no_profiled_libs+debug_ghc+debug_info`,
              then `hu run -d debug --freeze1 -j8`
          - Investigate a failing test: build first,
            then `hu run -d debug -j8 --freeze1 test --only="<test-name>" --keep-test-files -VVV`
          - If you're given commands using a different build-root, use it instead of `debug`
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
          attribution.commit = "AI assisted.";
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

        skills.socratic-tutor = "${inputs.janestreet-agent-skills}/socratic-tutor";
        skills.ghc-gitlab = "${inputs.fetch-gitlab}/skill/ghc-gitlab";

        skills.failing-tests-to-tmux = ''
          ---
          name: failing-tests-to-tmux
          description: Open one tmux window per failing GHC test, each in its kept .run dir with the repro command pre-typed. Use when asked to open tmux windows for failing tests from a `hu run ... test --only=...` run.
          ---

          # Failing GHC tests -> one tmux window each

          1. Re-run only the failing tests, keeping work dirs and printing invocations:
             `hu run -d <root> -j8 --freeze1 test --only="<failing tests>" -VVV --keep-test-files > /tmp/ft.log 2>&1`
             (same `-d <root>` the user used).

          2. The in-tree compiler is `_build-<root>/stage1/bin/ghc`
             Each test prints `=====> <name>(<way>) ...` then a `cd "<.run dir>" && <command> < ...`
             line (the dir has literal spaces). The `.run` dir is the window cwd; `<command>` is the
             repro -- drop the trailing ` < ...` and any diff text on that
             line, also drop -dno-debug-output from the flags

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

        skills.agent-tasks = ''
          ---
          name: agent-tasks
          description: Plan and track non-trivial, multi-step work as tasks with dependencies in `ta`, the taskwarrior database shared by all agents, potentially linked to the user's satisago task it serves.
          ---

          # Agent tasks with `ta`

          `ta` is `task` (taskwarrior) on a database shared by all agents,
          separate from the user's own. Write agent tasks only with `ta`; use
          `task` only to read and annotate the user's tasks.

          Refer to tasks by uuid

          ## Fields

          - `project:` always. Use the origin task's project (see `task <origin> information`)
            with a subproject for this piece of work, e.g. `haskell-debugger.global-breaks`.
            Without an origin, name it after the repository or thing worked on.
            Reuse names from `ta projects`.
          - `origin:<user-uuid>`: the full uuid of the satisago task the work
            serves. When started from satisago these are the uuids under `Tasks:`
            in the prompt; with several, each `ta` task takes the one it serves.
            Omit when there is none.
          - `depends:<uuid>,<uuid>`: the steps that must be done first.
          - `owner:` who is working on it, set when claiming.
          - `+followup`: work noticed that is out of scope, not to be done now.
          - `+question`: a decision only the user can make.
          - `+blocked`: waiting on something external.
          - Annotations: findings, decisions, paths, commands, results; whatever the next
            agent picking this up would need.

          ## Workflow

          1. Look for existing work first: `ta origin:<uuid> all`, `ta project:<p> board`.
             Continue it rather than planning again.
          2. Plan one task per meaningful step, not per command. `ta add` prints
             `Created task <uuid>.`, to use in later `depends:`.
             ```
             ta add project:p.x origin:<uuid> -- Reproduce the crash
             ta add project:p.x origin:<uuid> depends:<uuid> -- Fix the off-by-one in ...
             ```
          3. Loop: `ta project:p.x +READY board`, claim with
             `ta <uuid> start owner:$CLAUDE_CODE_SESSION_ID`, do the work,
             `ta <uuid> annotate -- <finding>`, `ta <uuid> done`. If the start fails the task
             is already started by another agent; take another. To give a task back:
             `ta <uuid> stop owner:`. Revise the plan as you learn: add steps, change
             `depends:`, `ta <uuid> delete` what is no longer needed.
          4. Finish with every task done, deleted, or tagged `+followup`, `+question` or
             `+blocked` with an annotation explaining it. Then annotate the origin:
             `task <origin> annotate -- <summary>; agent tasks: ta origin:<origin> all`.
             Never, ever close the origin task (`done`, `delete`, or otherwise), even when
             the work seems finished: only the user closes it.

          ## Collaborating

          Other agents and subagents share the database. Hand them the project and the uuids
          to take and tell them to use this skill. Subagents may share your session id, so tell
          each to claim under its own name: `ta <uuid> start owner:<name>`.

          `ta board` lists pending tasks with owner and dependencies; `ta <uuid> information`
          shows one; `ta export` gives JSON.
        '';
      };
    
      programs.codex = {
        enable = true;
        package = inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        context = globalContext;
      };
    };
}
