{ inputs, ... }:
{
  perSystem = { pkgs, lib, ... }:
    let
      ui-src = files: lib.fileset.toSource { root = ./ui; fileset = lib.fileset.unions files; };

      # Dear ImGui for browsers: the imgui-sys-v1 module the page loads beside
      # the dashboard, built by dear-imgui-rs' own tooling (its xtask) from the
      # same crates the dashboard uses, with only the core and imnodes.
      dear-imgui-rs = pkgs.fetchFromGitHub {
        owner = "Latias94";
        repo = "dear-imgui-rs";
        rev = "v0.22.0";
        hash = "sha256-oqP7IS2dqfh0EJ9SZ/EKHcvRCymmASLcOaPESbhG4rg=";
      };
      xtask = pkgs.rustPlatform.buildRustPackage {
        pname = "dear-imgui-xtask";
        version = "0.22.0";
        src = pkgs.runCommand "dear-imgui-xtask-src" { } ''
          mkdir -p $out/tools
          cp -r ${dear-imgui-rs}/xtask $out/
          cp -r ${dear-imgui-rs}/tools/build-support $out/tools/
          cp ${./ui/web/xtask/Cargo.toml} $out/Cargo.toml
          cp ${./ui/web/xtask/Cargo.lock} $out/Cargo.lock
        '';
        cargoLock.lockFile = ./ui/web/xtask/Cargo.lock;
        cargoBuildFlags = [ "-p" "xtask" ];
        # Emscripten 6 dropped `allocate`, which the provider never uses.
        postPatch = ''
          substituteInPlace xtask/src/main.rs --replace-fail '\"cwrap\",\"allocate\",' '\"cwrap\",'
        '';
        doCheck = false;
      };
      imgui-provider = pkgs.runCommand "imgui-sys-v1" {
        nativeBuildInputs = [ xtask pkgs.emscripten pkgs.python3 ];
        imgui = pkgs.fetchCrate { pname = "dear-imgui-sys"; version = "0.22.0"; hash = "sha256-MKiMMDRe4d6a946wPX7aHkTAbGDpxt7sg8TZ+Eoy6q4="; };
        imnodes = pkgs.fetchCrate { pname = "dear-imnodes-sys"; version = "0.22.0"; hash = "sha256-xwsFm11xU9qwx77JjtYf0merCKav1L/O4JbVEjY0Dc4="; };
      } ''
        export EM_CACHE=$TMPDIR/emscripten-cache
        mkdir -p src/extensions
        ln -s $imgui src/dear-imgui-sys
        ln -s $imnodes src/extensions/dear-imnodes-sys
        python3 - ${dear-imgui-rs}/tools/build-support/maintained_sources.json > inventory.json <<'EOF'
        import json, sys
        d = json.load(open(sys.argv[1]))
        d["sources"] = [s for s in d["sources"] if s["id"] in ("core", "imnodes")]
        kept = sorted((n for n in d["nested_submodules"] if n["parent"].startswith(("dear-imgui-sys/", "extensions/dear-imnodes-sys/"))), key=lambda n: n["package_order"])
        d["nested_submodules"] = [dict(n, package_order=i) for i, n in enumerate(kept)]
        json.dump(d, sys.stdout)
        EOF
        xtask build-cimgui-provider --source-root src --inventory inventory.json --out-dir $out
      '';
    in
    {
      # The server: listens to control-events and judges them. See protocol.md.
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
        src = ui-src [ ./ui/Cargo.toml ./ui/Cargo.lock ./ui/src ];
        cargoLock.lockFile = ./ui/Cargo.lock;
        env.IMGUI_SYS_BUILD_MODE = "source";
        meta.mainProgram = "control-dashboard";
      };

      # The same window, for browsers: the files the server serves at /.
      packages.control-dashboard-web = pkgs.stdenv.mkDerivation {
        pname = "control-dashboard-web";
        version = "0.3.0";
        src = ui-src [ ./ui/Cargo.toml ./ui/Cargo.lock ./ui/src ./ui/web/index.html ./ui/web/bundle.py ];
        cargoDeps = pkgs.rustPlatform.importCargoLock { lockFile = ./ui/Cargo.lock; };
        nativeBuildInputs = with pkgs; [ rustPlatform.cargoSetupHook cargo rustc lld wasm-bindgen-cli_0_2_127 wasm-tools python3 ];
        buildPhase = ''
          cargo build --offline --release --lib --target wasm32-unknown-unknown
        '';
        installPhase = ''
          python3 web/bundle.py target/wasm32-unknown-unknown/release/control_dashboard.wasm ${imgui-provider} $out
        '';
      };
    };
}
