{ self, ... }:
{
  flake.darwinModules.dashboard-dot = { config, lib, pkgs, ... }:
    let
      self-pkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
      cfg = config.control-dashboard.dot;
    in
    {
      options.control-dashboard.dot = {
        enable = lib.mkEnableOption "a menu bar dot, red while something is bad and amber while waiting";
        server = lib.mkOption {
          description = "The control-dashboard server the dot watches.";
          type = lib.types.str;
          default = "http://127.0.0.1:5001";
        };
        open = lib.mkOption {
          description = "The command clicking the dot runs, e.g. `[ \"open\" \"http://dash.localhost\" ]`.";
          type = lib.types.listOf lib.types.str;
          default = [ (lib.getExe self-pkgs.control-dashboard) "--server" cfg.server ];
          defaultText = lib.literalExpression ''[ (lib.getExe control-dashboard) "--server" cfg.server ]'';
        };
      };

      config = lib.mkIf cfg.enable {
        launchd.user.agents.control-dashboard-dot.serviceConfig = {
          ProgramArguments = [ (lib.getExe self-pkgs.control-dashboard-dot) "--server" cfg.server "--open" ] ++ cfg.open;
          RunAtLoad = true;
          KeepAlive = true;
          StandardErrorPath = "/tmp/org.romes.control-dashboard-dot.err.log";
        };
      };
    };
}
