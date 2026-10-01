{ inputs, ghcVersion, ... }:
{
  perSystem = { pkgs, lib, ... }: {
    packages.control-dashboard =
    let
      # ${ghcVersion} not up to date for servant et all
      hpkgs = pkgs.haskellPackages;
      control-events = hpkgs.callCabal2nix "control-events" inputs.control-events { };
    in pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "control-dashboard" ./. { inherit control-events; });
  };
}
