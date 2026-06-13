{ self, ... }:
{
  flake.darwinModules.dashboards = { config, lib, pkgs, ... }:
    let
      self-pkgs = self.packages.${pkgs.stdenv.hostPlatform.system};

      # Mirror the finances toggle: the dashboard only shows the finances
      # section (and queries hledger) when finances are enabled on this host.
      financesEnabled = config.finances.enable or false;

      # One --journal NAME=PATH per configured journal, so the dashboard reports
      # each journal's last reconciled date.
      journalArgs = lib.optionalString financesEnabled (lib.concatMapStringsSep " "
        (j: "--journal ${lib.escapeShellArg "${j.name}=${j.path}"}")
        config.finances.journals);
    in
    {
      # User daemon serving the control dashboard
      launchd.user.agents = {
        control-dashboard = {
          script = ''
            set -euo pipefail

            exec ${lib.getExe self-pkgs.control-dashboard} \
              --port 5001 \
              --host 127.0.0.1 \
              --finances ${if financesEnabled then "True" else "False"} ${journalArgs}
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
