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
    ayu-light = {
      vim = "ayu";
      background = "light";
      ghostty = "ayu_light";
    };
    ayu-dark = {
      vim = "ayu";
      background = "dark";
      ghostty = "ayu";
    };
    everforest = {
      vim = "everforest";
      ghostty = "Everforest Dark - Hard";
      background = "dark";
      extraSettings = {
        programs.nixvim.colorschemes.everforest.settings.background = "hard";
      };
    };
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
    style.colors.ayu-light.enable = lib.mkEnableOption "Ayu light";
    style.colors.ayu-dark.enable = lib.mkEnableOption "Ayu dark";
  };

  config = lib.mkMerge (
    lib.attrValues (lib.mapAttrs theme simpleThemes) ++
    [
    ]
    );
}
