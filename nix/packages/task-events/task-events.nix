{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.task-events =
    let
      hpkgs = pkgs.haskellPackages;
      control-events = pkgs.haskell.lib.dontCheck (hpkgs.callCabal2nix "control-events" inputs.control-events { });
    in pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "task-events" ./. { inherit control-events; });
  };
}
