{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    # Listens to control-events, judges them, and serves the page in
    # server/web, with the libraries and fonts it draws with. See protocol.md.
    packages.control-dashboard-server =
      let
        hpkgs = pkgs.haskellPackages;
        control-events = pkgs.haskell.lib.dontCheck (hpkgs.callCabal2nix "control-events" inputs.control-events { });
        server = pkgs.haskell.lib.justStaticExecutables
          (hpkgs.callCabal2nix "control-dashboard-server" ./server { inherit control-events; });
        npm = path: hash: pkgs.fetchurl { url = "https://cdn.jsdelivr.net/npm/${path}"; inherit hash; };
        vendor = {
          "elk.bundled.js" = npm "elkjs@0.9.3/lib/elk.bundled.js" "sha256-sHRavX8jzZFpChWH43ftvhn9cjPHgzACkJNnIFRiFtQ=";
          "d3.min.js" = npm "d3@7.9.0/dist/d3.min.js" "sha256-8glLv2FBs1lyLE/kVOtsSw8OQswQzHr5IfwVj864ZTk=";
          "simplex-noise.js" = npm "simplex-noise@2.4.0/simplex-noise.js" "sha256-u8njNpzE/7fzKRST7Eu38nECKwFREeLMkipUauqgPpY=";
          "fell.woff2" = npm "@fontsource/im-fell-english@5.0.13/files/im-fell-english-latin-400-normal.woff2" "sha256-JIMA3xZHvsSRVaXK2h1l9xmuYz70hWTR8ZsTWopbf18=";
          "fell-italic.woff2" = npm "@fontsource/im-fell-english@5.0.13/files/im-fell-english-latin-400-italic.woff2" "sha256-j8Z4V16Dho+Czlqm4CPwVupo1IDhbdEIs+FLw3XI/eo=";
          "cinzel.woff2" = npm "@fontsource/cinzel@5.2.8/files/cinzel-latin-600-normal.woff2" "sha256-Ye/CfOt9CLuEFlL6iXnAtoM7klSLf5VEwHlopsAvKOQ=";
          "echarts.min.js" = npm "echarts@5.5.1/dist/echarts.min.js" "sha256-6EJwvQzVvfYP78JtAMKjkcsugfTSanqe4WGFpUdzo88=";
          "three.min.js" = npm "three@0.147.0/build/three.min.js" "sha256-80RGv4dbX7Dc2TgZ/+HZ4YLUZjTuhV9dkExsSsfNvJU=";
          "GLTFLoader.js" = npm "three@0.147.0/examples/js/loaders/GLTFLoader.js" "sha256-su3akjVyxz5rMLE5dW0YLIfiw00CKEXG4GepoKlUTgE=";
          "OrbitControls.js" = npm "three@0.147.0/examples/js/controls/OrbitControls.js" "sha256-tMblP5hThTWxH9ZlVifUf7WHezrZclaL/wpwJsS21cQ=";
          "SkeletonUtils.js" = npm "three@0.147.0/examples/js/utils/SkeletonUtils.js" "sha256-rS3EMrDhDqMLGdyj382MA6XE1ihObGkfDG8bRacMOw0=";
        };
      in pkgs.runCommand "control-dashboard-server" {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = "control-dashboard-server";
      } ''
        mkdir -p $out/share/web/vendor
        cp -r ${./server/web}/. $out/share/web/
        ${pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (n: f: "cp ${f} $out/share/web/vendor/${n}\n") vendor)}
        makeWrapper ${pkgs.lib.getExe server} $out/bin/control-dashboard-server --add-flags "--web $out/share/web"
      '';
  };
}
