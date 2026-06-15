{ inputs, ghcVersion, ... }:
{
  perSystem = { pkgs, lib, ... }: {
    packages.control-dashboard =
    let
      # ${ghcVersion} not up to date for servant et all
      hpkgs = pkgs.haskellPackages;
    in pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "control-dashboard" ./. { });
  };
}
