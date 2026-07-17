{ ... }:
{
  perSystem = { pkgs, ... }: {
    packages.eventlog-activity =
    let
      hpkgs = pkgs.haskellPackages;
    in
      # justStaticExecutables keeps GHC out of the runtime closure.
      pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "eventlog-activity" ./. { });
  };
}
