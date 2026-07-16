{ ... }:
{
  perSystem = { pkgs, lib, ... }: {
    # speedscope's npm tarball already ships a prebuilt `dist/release` bundle, so
    # there's nothing to build: we just fetch it and wrap a small launcher (see
    # cli-wrapper.mjs for why upstream's launcher doesn't work from the store).
    packages.speedscope =
    let
      version = "1.25.0";
      src = pkgs.fetchzip {
        url = "https://registry.npmjs.org/speedscope/-/speedscope-${version}.tgz";
        hash = "sha256-/e0q1iARlJvawTtpuhz5nlQq0aZMc5A6+ATVL3xZ8Vc=";
      };
    in
    pkgs.runCommand "speedscope-${version}"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta = {
          description = "Interactive flamegraph visualizer (CLI wrapper that opens profiles in the browser)";
          homepage = "https://github.com/jlfwong/speedscope";
          license = lib.licenses.mit;
          mainProgram = "speedscope";
        };
      }
      ''
        libdir=$out/lib/speedscope
        mkdir -p $libdir
        cp -r ${src}/dist/release $libdir/release

        # Bake the (self-referential) release path into the launcher.
        cp ${./cli-wrapper.mjs} $libdir/cli.mjs
        substituteInPlace $libdir/cli.mjs \
          --replace-fail '@releaseDir@' "$libdir/release"

        mkdir -p $out/bin
        makeWrapper ${lib.getExe pkgs.nodejs} $out/bin/speedscope \
          --add-flags "$libdir/cli.mjs"
      '';
  };
}
