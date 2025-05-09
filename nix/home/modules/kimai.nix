{ pkgs, lib, config, ...}:
with lib;
let
  cfg = config.programs.kimai;
  kimaiSrc = builtins.fetchGit {
    url = "git@gitlab.well-typed.com:well-typed/kimai-client";
    rev = "a3aa72b157308e821b47473f2885e3ebe3ac1265";
    shallow = true;
  };
  kimaiPkg = pkgs.haskellPackages.callCabal2nix "kimai" kimaiSrc {
    optparse-applicative = pkgs.haskellPackages.callHackageDirect {
      pkg = "optparse-applicative";
      ver = "0.17.1.0";
      sha256 = "sha256-15FJobNwJladxpmOcVjFy54nKlqGoLnSxYqmxf3/zTc=";
    } {};
  };
  kimaiWrapper = pkgs.writeShellScriptBin "kimai" ''
    set -e
    AUTH_FILE="${cfg.authFile}"

    if [ ! -f "$AUTH_FILE" ]; then
      echo "Kimai auth file not found at $AUTH_FILE"
      exit 1
    fi

    source "$AUTH_FILE"

    if [ -z "$KIMAI_USER" ] || [ -z "$KIMAI_TOKEN" ]; then
      echo "KIMAI_USER or KIMAI_TOKEN not set in $AUTH_FILE"
      exit 1
    fi

    exec ${kimaiPkg}/bin/kimai "$@"
  '';
in
{
  options.programs.kimai = {
    enable = mkEnableOption "Kimai CLI setup";
    server = mkOption {
      description = "Server domain";
      type = types.str;
    };
    port = mkOption {
      description = "Server domain";
      type = types.int;
      default = 443;
    };
    alias-project = mkOption {
      description = "Maps project Ids to aliases";
      type = types.attrsOf types.str;
      default = {
        P123 = "A";
        P246 = "B";
      };
    };
    alias-activity = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Mapping of activity Ids to aliases";
      example = {
        A16 = "B";
        A17 = "NB";
      };
    };
    authFile = mkOption {
      type = types.path;
      description = "Path to a file exporting KIMAI_USER and KIMAI_TOKEN environment variables";
    };
  };

  config = mkIf cfg.enable {
    home.activation.kimaiSetup = lib.hm.dag.entryAfter ["writeBoundary"] ''
      echo "Configuring Kimai CLI..."

      ${kimaiWrapper}/bin/kimai server ${cfg.server}
      ${kimaiWrapper}/bin/kimai port ${toString cfg.port}

      ${concatStringsSep "\n" (lib.mapAttrsToList (id: alias: "${kimaiWrapper}/bin/kimai alias-project ${id} ${alias}") cfg.alias-project)}
      ${concatStringsSep "\n" (lib.mapAttrsToList (id: alias: "${kimaiWrapper}/bin/kimai alias-activity ${id} ${alias}") cfg.alias-activity)}
    '';

    # Make kimai available as the wrapper that sets the right variables from the secret.
    home.packages = [ kimaiWrapper ];
  };
}

