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

      satisago-script = pkgs.writeShellScriptBin "satisago" ''
        exec nvim "${cfg.root}/projects/current/" "$@"
      '';
    in
    {
      options.programs.satisago = {
        enable = lib.mkEnableOption "satisago nvim plugin";
        root = lib.mkOption {
          type = lib.types.str;
          description = ''
            Full path to the satisago root directory.
            Files within this root get satisago-specific nvim behaviour.
          '';
        };
      };

      config = lib.mkIf cfg.enable {

        home.packages = [ satisago-script ];
        programs.zsh.shellAliases.sg = "satisago";

        programs.nixvim = {
          extraPlugins = [ satisago-plugin ];
          globals.satisago_root = cfg.root;
          keymaps = [
            {
              mode = "n";
              key = "<leader>sg";
              action = "<cmd>Satisago open<cr>";
              options.desc = "satisago: open projects list";
            }
            {
              mode = "n";
              key = "<leader>sp";
              action = "<cmd>Git pull<cr>";
              options.desc = "satisago: git pull";
            }
          ];
        };
      };
    };
}
