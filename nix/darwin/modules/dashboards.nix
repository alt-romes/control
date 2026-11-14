{ self, ... }:
{
  flake.darwinModules.dashboards = { config, lib, pkgs, ... }:
    let
      self-pkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
      cfg = config.control-dashboard;
      flags = name: lib.concatMapStringsSep " " (v: "--${name} ${lib.escapeShellArg v}");
      triggers = lib.unique (lib.mapAttrsToList (_: a: a.on) (lib.filterAttrs (_: a: a.dashboardTrigger) config.automations));
    in
    {
      options.automations = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.dashboardTrigger = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Offer the trigger it reacts to, its `on`, for sending from the dashboard.";
          };
        });
      };

      options.control-dashboard = {
        requiredHealthchecks = lib.mkOption {
          description = ''
            Topics that must always be running: each is a problem until a run
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
      };

      config = {
        assertions = lib.mapAttrsToList (name: a: {
          assertion = !a.dashboardTrigger || (a.on != null && lib.hasPrefix "trigger/" a.on && !lib.hasInfix "+" a.on && !lib.hasInfix "#" a.on);
          message = "automations.${name}: a dashboardTrigger needs on = \"trigger/...\", with no wildcards.";
        }) config.automations;

        # The server judging every control-event, for the dashboard's windows
        automations.control-dashboard = {
          keepAlive = true;
          script = ''
            exec ${lib.getExe self-pkgs.control-dashboard-server} \
              --port 5001 \
              --host 127.0.0.1 \
              ${flags "require" cfg.requiredHealthchecks} \
              ${flags "trigger" triggers} \
              ${flags "logs" (lib.optional (cfg.logPattern != null) cfg.logPattern)}
          '';
        };

        # Reachable locally and on the wireguard VPN, by windows and browsers.
        services.caddy.virtualHosts = {
          "dash.localhost"     = "127.0.0.1:5001";
          "control.mogbit.com" = "127.0.0.1:5001";
        };

        environment.systemPackages = [ self-pkgs.control-dashboard ];
      };
    };
}
