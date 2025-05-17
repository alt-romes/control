{ config, pkgs, lib, inputs, ... }:
let
  simpleThemes = {
    # colorschemes.ayu.enable = true;
    # colorschemes.kanagawa.enable = true;
    oxocarbon = {
      vim = "oxocarbon";
      ghostty = "oxocarbon";
      background = "dark";
    };
    everforest = {
      vim = "everforest";
      ghostty = "Everforest Dark - Hard";
      background = "dark";
      extraSettings = {
        programs.nixvim.colorschemes.everforest.settings.background = "hard";
      };
    };
    # ayu-light = { vim = "ayu"; ghostty = "ayu"; background = "light"; };
  };

  theme = themeName: themeConf:
    let opt = config.style.colors.${themeName};
        base = {
          programs.ghostty.settings.theme = themeConf.ghostty;
          programs.nixvim.colorschemes.${themeConf.vim}.enable = true;
          programs.nixvim.opts.background = themeConf.background; # "light" or "dark"
        };
        extra = if themeConf ? extraSettings then themeConf.extraSettings else {};
    in lib.mkIf (opt.enable) (lib.recursiveUpdate base extra);
in
{

  options = {
    style.colors.oxocarbon.enable = lib.mkEnableOption "Oxocarbon dark";
    style.colors.everforest.enable = lib.mkEnableOption "Everforest dark hard";
    # style.colors.ayu.enable = lib.mkEnableOption "Ayu light";
  };

  config = lib.mkMerge (
    lib.attrValues (lib.mapAttrs theme simpleThemes) ++
    [
    ]
    );
}
