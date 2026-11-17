{ self, ... }:
{
  flake.darwinModules.dashboard-dot = { config, lib, pkgs, ... }:
    let
      self-pkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
      cfg = config.control-dashboard.dot;
    in
    {
      options.control-dashboard.dot = {
        enable = lib.mkEnableOption "a menu bar dot, red while something is bad, amber while waiting and green otherwise";
        server = lib.mkOption {
          description = "The control-dashboard server the dot watches.";
          type = lib.types.str;
          default = "http://127.0.0.1:5001";
        };
        open = lib.mkOption {
          description = "The command clicking the dot runs.";
          type = lib.types.listOf lib.types.str;
          default = [ "open" "http://dash.localhost" ];
        };
      };

      config = lib.mkIf cfg.enable {
        automations.control-dashboard-dot = {
          keepAlive = true;
          script = "exec ${lib.escapeShellArgs ([ (lib.getExe self-pkgs.control-dashboard-dot) "--server" cfg.server "--open" ] ++ cfg.open)}";
        };
      };
    };
}
