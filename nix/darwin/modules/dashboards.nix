{ self, ... }:
{
  flake.darwinModules.dashboards = { config, lib, pkgs, ... }:
    let
      self-pkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      # User daemon serving the control dashboard
      launchd.user.agents = {
        control-dashboard = {
          script = ''
            set -euo pipefail

            exec ${lib.getExe self-pkgs.control-dashboard} \
              --port 5001 \
              --host 127.0.0.1
          '';

          serviceConfig = {
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath   = "/tmp/org.romes.control-dashboard.out.log";
            StandardErrorPath = "/tmp/org.romes.control-dashboard.err.log";
          };
        };
      };

      # Map dashboard.localhost to the control dashboard
      services.caddy = {
        virtualHosts = {
          "dashboard.localhost" = "127.0.0.1:5001";
        };
      };
    };
}
