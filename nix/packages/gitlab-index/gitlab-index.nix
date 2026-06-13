{ inputs, ghcVersion, ... }:
{
  perSystem = { pkgs, lib, ... }: {
    packages.gitlab-index =
    let
      hpkgs = pkgs.haskell.packages.${ghcVersion};

      # cabal2nix derivation; justStaticExecutables keeps GHC out of the runtime
      # closure (so this is a small leaf package, not a Haskell dev env).
      unwrapped = pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "gitlab-index" ./. { });

      # Runtime CLIs the tool shells out to.
      runtimeDeps = [ pkgs.glab pkgs.fzf pkgs.glow pkgs.ripgrep ];

      gitlab-index = pkgs.runCommand "gitlab-index"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          meta = unwrapped.meta // { mainProgram = "gitlab-index"; };
        } ''
        mkdir -p $out/bin
        makeWrapper ${unwrapped}/bin/gitlab-index $out/bin/gitlab-index \
          --set GITLAB_INDEX_SELF $out/bin/gitlab-index \
          --prefix PATH : ${lib.makeBinPath runtimeDeps}
      '';
    in gitlab-index;
  };
}
