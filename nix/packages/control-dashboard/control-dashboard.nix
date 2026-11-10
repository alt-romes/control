{ inputs, ... }:
{
  perSystem = { pkgs, lib, ... }: {
    # The server: listens to control-events, judges them, and serves the
    # dashboard to its windows and, as a page, to browsers. See protocol.md.
    packages.control-dashboard-server =
      let
        hpkgs = pkgs.haskellPackages;
        control-events = pkgs.haskell.lib.dontCheck (hpkgs.callCabal2nix "control-events" inputs.control-events { });
      in pkgs.haskell.lib.justStaticExecutables
          (hpkgs.callCabal2nix "control-dashboard-server" ./server { inherit control-events; });

    # A window onto the server.
    packages.control-dashboard = pkgs.rustPlatform.buildRustPackage {
      pname = "control-dashboard";
      version = "0.3.0";
      src = lib.fileset.toSource { root = ./ui; fileset = lib.fileset.unions [ ./ui/Cargo.toml ./ui/Cargo.lock ./ui/src ]; };
      cargoLock.lockFile = ./ui/Cargo.lock;
      env.IMGUI_SYS_BUILD_MODE = "source";
      meta.mainProgram = "control-dashboard";
    };
  };
}
