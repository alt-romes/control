{ inputs, ... }:
{
  flake.homeModules.llm = { config, lib, pkgs, ... }:
    let
      mkSkillEntry =
        name: content:
        lib.nameValuePair ".codex/skills/${name}" {
          source = pkgs.writeTextDir "SKILL.md" (if lib.isPath content then builtins.readFile content else content);
          recursive = true;
        };
    
      aiContext =
        ''
          - When a dependency is not available, use `nix` to temporarily make it available.
            Don't use nix for things which are already available, like the Haskell toolchain.
            (Example: nix-shell -p python3 python3Packages.matplotlib --run 'python3 script.py')
          - Use unqualified imports in Haskell by default. Use qualified imports only when that's the convention or necessary.
          - To browse Haskell dependencies use `cabal repl` to enter a REPL with the project packages.
            To browse a package which is not yet a dependency of the project, use `cabal repl --build-depends=<pkg>`.
            Do not look around with `ghc-pkg` nor directly for interface files
          - In a GHC source-tree, use `./hadrian/ghci` to typecheck GHC
          - Use --no-ext-diff when viewing git diffs
        '';
            # use `hu build-root init <name> --flavour=<flavour>` and `hu run -d <name> -j8` for full build
    in
    {
    
      programs.claude-code = {
        enable = true;
        package = inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        context = aiContext;
      };
    
      # Write to .codex/skills additionally, because programs.codex.skills are only
      # written to .agents/skills which codex cli still doesn't recognize
      home.file = lib.mapAttrs' mkSkillEntry config.programs.codex.skills;
    
      programs.codex = {
        enable = true;
        package = inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
    
        context = aiContext;
    
        settings = {
          model = "gpt-5.4";
          model_reasoning_effort = "medium";
    
          projects = {
            "/Users/romes/Developer/ghc-debugger".trust_level = "trusted";
            "/Users/romes/ghc-dev/ghc".trust_level = "trusted";
            "/Users/romes/control".trust_level = "trusted";
          };
        };
      };
    };
}
