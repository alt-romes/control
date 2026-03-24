{ config, lib, pkgs, inputs, ... }:
let
  mkSkillEntry =
    name: content:
    lib.nameValuePair ".codex/skills/${name}" {
      source = pkgs.writeTextDir "SKILL.md" (if lib.isPath content then builtins.readFile content else content);
      recursive = true;
    };
in
{
  # Write to .codex/skills additionally, because programs.codex.skills are only
  # written to .agents/skills which codex cli still doesn't recognize
  home.file = lib.mapAttrs' mkSkillEntry config.programs.codex.skills;

  programs.codex = {
    enable = true;
    package = inputs.codex-cli-nix.packages.${pkgs.system}.default;

    custom-instructions =
      ''
        - When a dependency is not available, use `nix` to temporarily make it available (like
          nodejs). Don't use nix for things which are already available, like the Haskell toolchain.
          (Example: nix-shell -p python3 python3Packages.matplotlib --run 'python3 script.py')
      '';

    skills = {
      hadrian_test = ''
        ---
        name: hadrian
        description: Hadrian is GHC's build system. You should run hadrian to build GHC and to test specific tests from the GHC testsuite
        ---

        The default hadrian (`./hadrian/build`) GHC build system is wrapped as a shell function `hadrian`:
        To build GHC from scratch run
        ```
        hadrian
        ```

        This will re-use the existing tree flavour. If no flavour is already defined, use by default:
        ```
        hadrian --flavour=perf+no_profiled_libs+debug_ghc+debug_info
        ```

        If you want to fix stage1, run with
        ```
        hadrian <flavour if needed> --freeze1
        ```

        ## Running a test

        To run a specific test, first build the tree as described above.
        The flavour will be recorded and then you can run the test through
        hadrian first to get a result:
        ```
        hadrian --freeze1 test --only="T12345"
        ```

        Once the test runs the first time, run it again with additional flags
        to preserve temporary files and print out the direct command line invocation:
        ```
        hadrian --freeze1 test --only="<test>" -k -V
        ```

        From the output of the previous command, you should capture the command
        line invocation (it will look like `cd <testsuite directory> &&
        .../_build/stage1/bin/ghc <args>`).

        Now, run that ghc invocation directly. Make sure to remove
        `-dno-debug-output` and other flags which suppress output to ensure the
        compiler output is visible.

        ## Profiling GHC while running a test

        If the compiler flavour (consult `_build/flavour.txt` in the GHC root)
        is profiled (includes `+profiled_ghc`), then you can run the ghc
        invocation with additional flags `+RTS -pj -RTS` to produce a JSON
        `*.prof` profile file which can be visualized as a flamegraph in
        speedscope.app. You can also use `+RTS -p -RTS` to produce a `.prof`
        file which uses a GHC format for displaying the same information in a
        more human readable way but which can still be read by a machine.
        '';
    };

    settings = {
      model = "gpt-5.4";
      model_reasoning_effort = "medium";

      projects = {
        "/Users/romes/Developer/ghc-debugger".trust_level = "trusted";
        "/Users/romes/ghc-dev/ghc".trust_level = "trusted";
        "/Users/romes/control".trust_level = "trusted";
      };

      mcp_servers.haskell = {
        # HLS speaks LSP, so use an LSP-to-MCP bridge for Codex.
        command = "${pkgs.nodejs}/bin/npx";
        startup_timeout_sec = 60;
        args = [
          "--quiet"
          "-y"
          "tritlo/lsp-mcp"
          "haskell"
          "${pkgs.haskell-language-server}/bin/haskell-language-server-wrapper"
          "--lsp"
        ];
      };
    };
  };
}
