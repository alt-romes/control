{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    # Listens to control-events, judges them, and serves the dashboard as JSON
    # to control-mindustry. See protocol.md.
    packages.control-dashboard-server =
      let
        hpkgs = pkgs.haskellPackages;
        control-events = pkgs.haskell.lib.dontCheck (hpkgs.callCabal2nix "control-events" inputs.control-events { });
      in pkgs.haskell.lib.justStaticExecutables
          (hpkgs.callCabal2nix "control-dashboard-server" ./server { inherit control-events; });
  };
}
