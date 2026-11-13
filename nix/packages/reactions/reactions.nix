{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.reactions =
    let
      hpkgs = pkgs.haskellPackages;
      control-events = pkgs.haskell.lib.dontCheck (hpkgs.callCabal2nix "control-events" inputs.control-events { });
    in pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "reactions" ./. { inherit control-events; });
  };
}
