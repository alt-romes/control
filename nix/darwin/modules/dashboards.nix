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
        logPattern = lib.mkOption {
          description = ''
            Where scripts' logs are, with `%s` for the last level of their
            topic: a failed run shows the end of its log.
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        alertCommand = lib.mkOption {
          description = ''
            Shell command run for each new thing needing attention, given as
            `$1`, e.g. `curl -s -d "$1" ntfy.sh/<topic>`.
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };

      config = {
        # User daemon serving the control dashboard
        launchd.user.agents = {
          control-dashboard = {
            script = ''
              exec ${lib.getExe self-pkgs.control-dashboard} \
                --port 5001 \
                --host 127.0.0.1 \
                --persistent \
                ${flags "require" cfg.requiredHealthchecks} \
                ${flags "logs" (lib.optional (cfg.logPattern != null) cfg.logPattern)} \
                ${flags "alert" (lib.optional (cfg.alertCommand != null) cfg.alertCommand)}
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
