{ ... }:
{
  flake.homeModules.satisago = { config, lib, pkgs, ... }:
    let
      cfg = config.programs.satisago;

      pluginSrc = pkgs.runCommand "satisago-nvim-src" { } ''
        mkdir -p $out/plugin
        cp ${./satisago/satisago.lua} $out/plugin/satisago.lua
      '';

      satisago-plugin = pkgs.vimUtils.buildVimPlugin {
        pname = "satisago-nvim";
        version = "0.1.0";
        src = pluginSrc;
      };
    in
    {
      options.programs.satisago = {
        enable = lib.mkEnableOption "satisago nvim plugin";
        root = lib.mkOption {
          type = lib.types.str;
          description = ''
            Full path to the satisago root directory. Files within this root
            get satisago-specific nvim behaviour (currently: .md files have
            completed todo lines concealed).
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        programs.nixvim.extraPlugins = [ satisago-plugin ];
        programs.nixvim.globals.satisago_root = cfg.root;
      };
    };
}
