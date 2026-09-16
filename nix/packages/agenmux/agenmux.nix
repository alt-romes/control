{ inputs, ... }:
{
  # agenmux (https://github.com/snirt/agenmux): a tmux plugin that monitors AI
  # coding agents running in your panes (sidebar + status-line segment).
  #
  # Upstream self-manages: its agenmux.tmux downloads/builds a native engine into
  # its own checkout and self-updates. That can't work from a read-only store, so
  # we build the engine ourselves and point the bootstrap at it. With BIN set to
  # our store binary the bootstrap takes its "already installed" path (it only
  # checks Cargo.toml version + `agenmux --version`) and never downloads or writes.
  #
  # Source is the `agenmux-src` flake input, so `nix flake update` bumps it and the
  # Rust deps re-vendor straight from the input's Cargo.lock — no hashes to chase.
  perSystem = { pkgs, lib, ... }:
    let
      src = inputs.agenmux-src;
      version = "0-unstable-${builtins.substring 0 8 src.lastModifiedDate}";

      engine = pkgs.rustPlatform.buildRustPackage {
        pname = "agenmux-engine";
        inherit version src;
        cargoLock.lockFile = "${src}/Cargo.lock";
        doCheck = false;
        meta.mainProgram = "agenmux";
      };
    in
    {
      packages.agenmux = pkgs.tmuxPlugins.mkTmuxPlugin {
        pluginName = "agenmux";
        inherit version src;
        rtpFilePath = "agenmux.tmux";

        # Default the engine binary to our store build.
        postPatch = ''
          substituteInPlace agenmux.tmux \
            --replace-fail '[ -n "$BIN" ] || BIN="$DEFAULT_BIN"' \
                           '[ -n "$BIN" ] || BIN="${lib.getExe engine}"'
        '';

        meta = {
          description = "tmux plugin that monitors AI coding agents in your panes";
          homepage = "https://github.com/snirt/agenmux";
          license = lib.licenses.mit;
        };
      };
    };
}
