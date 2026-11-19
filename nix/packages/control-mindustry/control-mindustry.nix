{
  perSystem = { pkgs, lib, ... }:
    let
      mindustry = pkgs.fetchurl {
        url = "https://github.com/Anuken/Mindustry/releases/download/v160.5/Mindustry.jar";
        sha256 = "0wn23lkfzwlicja651c6adgx5m1p2892izs7pcjnac4drdfmmzf2";
      };
      mod = pkgs.stdenv.mkDerivation {
        pname = "control-mindustry-mod";
        version = "0.1.0";
        src = ./mod;
        nativeBuildInputs = [ pkgs.jdk17 ];
        buildPhase = ''
          javac --release 17 -Xlint:all -Werror -cp ${mindustry} -d classes control/*.java
          cp mod.hjson classes/
          jar cf control.jar -C classes .
        '';
        installPhase = ''
          install -Dm644 control.jar $out/control.jar
        '';
      };
    in
    {
      # Mindustry with a mod drawing the control-dashboard server as a factory
      # floor, in a data directory of its own.
      packages.control-mindustry = pkgs.writeShellApplication {
        name = "control-mindustry";
        text = ''
          data="''${XDG_STATE_HOME:-$HOME/.local/state}/control-mindustry"
          mkdir -p "$data/mods"
          ln -sf ${mod}/control.jar "$data/mods/control.jar"
          export MINDUSTRY_DATA_DIR="$data"
          exec ${lib.getExe' pkgs.jdk17 "java"} ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "-XstartOnFirstThread"} \
            -Dcontrol.url="''${1:-http://127.0.0.1:5001}" -jar ${mindustry}
        '';
      };
    };
}
