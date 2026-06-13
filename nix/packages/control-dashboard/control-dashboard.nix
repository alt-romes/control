{ inputs, ghcVersion, ... }:
{
  perSystem = { pkgs, lib, ... }: {
    packages.control-dashboard =
    let
      # ${ghcVersion} not up to date for servant et all
      hpkgs = pkgs.haskellPackages;

      unwrapped = pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "control-dashboard" ./. { });

    in unwrapped // {
      meta = unwrapped.meta // { mainProgram = "control-dashboard"; };
    };
  };
}
