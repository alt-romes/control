{ inputs, ghcVersion, ... }:
{
  perSystem = { pkgs, lib, ... }: {
    packages.control-dashboard =
    let
      # ${ghcVersion} not up to date for servant et all
      hpkgs = pkgs.haskellPackages;

      unwrapped = pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "control-dashboard" ./. { });

      # The --finances section shells out to hledger to read the journal.
      runtimeDeps = [ pkgs.hledger ];

    in pkgs.runCommand "control-dashboard"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta = unwrapped.meta // { mainProgram = "control-dashboard"; };
      } ''
      mkdir -p $out/bin
      makeWrapper ${unwrapped}/bin/control-dashboard $out/bin/control-dashboard \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
    '';
  };
}
