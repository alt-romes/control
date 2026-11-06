{
  perSystem = { pkgs, lib, ... }: {
    # A dot in the macOS menu bar while something is wrong. See ../../../darwin/modules/dashboard-dot.nix.
    packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      control-dashboard-dot = pkgs.stdenv.mkDerivation {
        pname = "control-dashboard-dot";
        version = "0.1.0";
        src = ./dot.swift;
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.swift ];
        buildPhase = ''
          swiftc -O -o control-dashboard-dot $src
        '';
        installPhase = ''
          install -Dm755 control-dashboard-dot $out/bin/control-dashboard-dot
        '';
        meta.mainProgram = "control-dashboard-dot";
      };
    };
  };
}
