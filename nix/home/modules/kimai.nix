{ pkgs, lib, config, ...}:
with lib;
let
  cfg = config.programs.kimai;
  kimaiSrc = pkgs.fetchFromGitLab {
    domain = "gitlab.well-typed.com";
    owner = "well-typed";
    repo = "kimai-client";
    rev = "main";
    # sha256 = "sha256-...";
  };
  kimaiPkg = pkgs.haskellPackages.callCabal2nix "kimai" kimaiSrc {};
  kimaiWrapper = pkgs.writeShellScriptBin "kimai" ''
    set -e
    AUTH_FILE="${cfg.authFile}"

    if [ ! -f "$AUTH_FILE" ]; then
      echo "Kimai auth file not found at $AUTH_FILE"
      exit 1
    fi

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
      type = types.str;
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

      kimai server ${cfg.server}
      kimai port ${cfg.port}

      ${concatStringsSep "\n" (lib.mapAttrsToList (id: alias: "kimai alias-project ${id} ${alias}") cfg.alias-project)}
      ${concatStringsSep "\n" (lib.mapAttrsToList (id: alias: "kimai alias-activity ${id} ${alias}") cfg.alias-activity)}
    '';

    # Make kimai available as the wrapper that sets the right variables from the secret.
    home.packages = [ kimaiWrapper ];
  };
}

