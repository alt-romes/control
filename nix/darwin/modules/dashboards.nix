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
        notes = lib.mkOption {
          description = ''
            Directories of Markdown and Org notes whose `- [ ]` checkboxes the
            dashboard shows, and ticks.
          '';
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        claude = lib.mkOption {
          description = ''
            The claude CLI, to diagnose runs that went wrong. It only replies:
            no tools, settings or MCP servers, in a sandbox that can't read the
            home directory.
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };

      config = {
        # The server judging every control-event, for the dashboard's windows
        launchd.user.agents.control-dashboard = {
          script = ''
            exec ${lib.getExe self-pkgs.control-dashboard-server} \
              --port 5001 \
              --host 127.0.0.1 \
              --web ${self-pkgs.control-dashboard-web} \
              ${flags "require" cfg.requiredHealthchecks} \
              ${flags "logs" (lib.optional (cfg.logPattern != null) cfg.logPattern)} \
              ${flags "notes" cfg.notes} \
              ${flags "claude" (lib.optional (cfg.claude != null) cfg.claude)}
          '';
          serviceConfig = {
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath   = "/tmp/org.romes.control-dashboard.out.log";
            StandardErrorPath = "/tmp/org.romes.control-dashboard.err.log";
          };
        };

        # Reachable locally and on the wireguard VPN, for windows elsewhere;
        # browsers get the dashboard itself at dash.localhost.
        services.caddy.virtualHosts = {
          "dash.localhost"     = "127.0.0.1:5001";
          "control.mogbit.com" = "127.0.0.1:5001";
        };

        environment.systemPackages = [ self-pkgs.control-dashboard ];
      };
    };
}
