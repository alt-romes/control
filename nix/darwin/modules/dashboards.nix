{ self, ... }:
{
  flake.darwinModules.dashboards = { config, lib, pkgs, ... }:
    let
      self-pkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
      cfg = config.control-dashboard;
      flags = name: lib.concatMapStringsSep " " (v: "--${name} ${lib.escapeShellArg v}");
    in
    {
      options.control-dashboard = {
        requiredHealthchecks = lib.mkOption {
          description = ''
            Topics that must always be running: each is a crisis until a run
            of it is seen.
          '';
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        links = lib.mkOption {
          description = "Hosts linked to in the dashboard's header";
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
      };

      config = {
        # User daemon serving the control dashboard
        launchd.user.agents = {
          control-dashboard = {
            script = ''
              set -euo pipefail

              STATE="$HOME/.local/state/control-dashboard/runs.json"
              mkdir -p "$(dirname "$STATE")"

              exec ${lib.getExe self-pkgs.control-dashboard} \
                --port 5001 \
                --host 127.0.0.1 \
                --persistent \
                --state "$STATE" \
                ${flags "require" cfg.requiredHealthchecks} \
                ${flags "link" cfg.links}
            '';

            serviceConfig = {
              RunAtLoad = true;
              KeepAlive = true;
              StandardOutPath   = "/tmp/org.romes.control-dashboard.out.log";
              StandardErrorPath = "/tmp/org.romes.control-dashboard.err.log";
            };
          };
        };

        # Serve the control dashboard locally and on the wireguard VPN
        services.caddy = {
          virtualHosts = {
            "dash.localhost"     = "127.0.0.1:5001";
            "control.mogbit.com" = "127.0.0.1:5001";
          };
        };
      };
    };
}
