{ inputs, ghcVersion, ... }:
{
  perSystem = { pkgs, lib, ... }: {
    packages.prof-diff-test =
    let
      hpkgs = pkgs.haskellPackages; # ghcVersion hasn't caught up, stick to default

      # cabal2nix derivation; justStaticExecutables keeps GHC out of the runtime
      # closure (so this is a small leaf package, not a Haskell dev env).
      unwrapped = pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "prof-diff-test" ./. { });

      # Runtime CLIs the tool shells out to: hadrian-util to run the tests, and
      # flamegraph (flamegraph.pl / difffolded.pl) to render the graphs.
      runtimeDeps = [
        inputs.hadrian-util.packages.${pkgs.stdenv.hostPlatform.system}.default
        pkgs.flamegraph
      ];

      prof-diff-test = pkgs.runCommand "prof-diff-test"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          meta = unwrapped.meta // { mainProgram = "prof-diff-test"; };
        } ''
        mkdir -p $out/bin
        makeWrapper ${unwrapped}/bin/prof-diff-test $out/bin/prof-diff-test \
          --prefix PATH : ${lib.makeBinPath runtimeDeps}
      '';
    in prof-diff-test;
  };
}
