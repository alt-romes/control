{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.caddy;

  # Generate the Caddyfile based on the simple key-value pairs
  caddyfile = pkgs.writeText "Caddyfile" (
    # extra config...
    ''
    {
      auto_https off
    }
    ''
    +
    (
      lib.concatStringsSep "\n" (
        # Use http:// prefix to say we want http only.
        # Assumes we only care about localhost names (like <name>.localhost)
        lib.mapAttrsToList (domain: target: ''
          http://${domain} {
            reverse_proxy ${target}
          }
        '') cfg.virtualHosts
      )
    )
  );
in
{
  options.services.caddy = {
    enable = lib.mkEnableOption "Caddy web reverse proxy";

    virtualHosts = lib.mkOption {
      # This matches your requested syntax: attrsOf strings
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Map of domains to proxy targets (e.g., '127.0.0.1:5000'). Note: <name>.localhost domains are always forward to 127.0.0.1, so you can use those as virtual hosts.";
    };
  };

  config = mkIf cfg.enable {
    launchd.user.agents.caddy = {
      serviceConfig = {
        ProgramArguments = [ "${pkgs.caddy}/bin/caddy" "run" "--config" "${caddyfile}" "--adapter" "caddyfile" ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "/tmp/org.romes.caddy.log";
        StandardErrorPath = "/tmp/org.romes.caddy.error.log";
      };
    };
  };
}
