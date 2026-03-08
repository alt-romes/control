{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.caddy;

  # Generate the Caddyfile based on the simple key-value pairs
  caddyfile = pkgs.writeText "Caddyfile" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (domain: target: ''
        http://${domain} {
          reverse_proxy ${target}
        }
      '') cfg.virtualHosts
    )
  );
in
{
  options.services.caddy = {
    enable = lib.mkEnableOption "Caddy reverse proxy";

    virtualHosts = lib.mkOption {
      # This matches your requested syntax: attrsOf strings
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Map of domains to proxy targets (e.g., '127.0.0.1:5000').";
    };
  };

  config = mkIf cfg.enable {
    launchd.daemons.caddy = {
      serviceConfig = {
        ProgramArguments = [ "${pkgs.caddy}/bin/caddy" "run" "--config" "${caddyfile}" "--adapter" "caddyfile" ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "/var/log/caddy.log";
        StandardErrorPath = "/var/log/caddy.error.log";
      };
    };
  };
}
