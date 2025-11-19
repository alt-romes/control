{ config, pkgs, lib, inputs, ... }:
let
  simpleThemes = {
    oxocarbon = {
      vim = "oxocarbon";
      ghostty = "oxocarbon";
      background = "dark";
    };
    ayu-light = {
      vim = "ayu";
      background = "light";
      ghostty = "Ayu Light";
    };
    ayu-dark = {
      vim = "ayu";
      background = "dark";
      ghostty = "Ayu";
    };
    everforest = {
      vim = "everforest";
      ghostty = "Everforest Dark - Hard";
      background = "dark";
      extraSettings = {
        programs.nixvim.colorschemes.everforest.settings.background = "hard";
      };
    };
    hotblue = {
      vim-colorscheme = "blue";
      background = "dark";
      ghostty = "Hot Dog Stand";
    };
    github = {
      vim = "github-theme";
      vim-colorscheme = "github_light_default";
      background = "light";
      ghostty = "GitHub";
    };
    kanagawa = {
      vim = "kanagawa";
      vim-colorscheme = "kanagawa-dragon";
      background = "dark";
      ghostty = "Kanagawa Dragon";
    };
    gruvbox-light = {
      vim = "gruvbox";
      background = "light";
      ghostty = "Gruvbox Light";
    };
    gruvbox-dark = {
      vim = "gruvbox";
      background = "dark";
      ghostty = "Gruvbox Dark";
    };
  };

  theme = themeName: themeConf:
    let opt = config.style.colors.${themeName};
        base = {
          programs.ghostty.settings.theme = themeConf.ghostty;
          programs.nixvim.opts.background = themeConf.background; # "light" or "dark"
        };
        # Either vim or vim-builtin is defined
        vim1 = (if themeConf ? vim then {
          programs.nixvim.colorschemes.${themeConf.vim}.enable = true;
        } else {});
        vim2 = (if themeConf ? vim-colorscheme then {
            programs.nixvim.colorscheme = themeConf.vim-colorscheme;
          } else {});
        extra = if themeConf ? extraSettings then themeConf.extraSettings else {};
    in lib.mkIf (opt.enable) (lib.recursiveUpdate (lib.recursiveUpdate base (lib.recursiveUpdate vim1 vim2)) extra);
in
{

  options = {
    style.colors.oxocarbon.enable = lib.mkEnableOption "Oxocarbon dark";
    style.colors.everforest.enable = lib.mkEnableOption "Everforest dark hard";
    style.colors.ayu-light.enable = lib.mkEnableOption "Ayu light";
    style.colors.ayu-dark.enable = lib.mkEnableOption "Ayu dark";
    style.colors.hotblue.enable = lib.mkEnableOption "Hot-Blue";
    style.colors.github.enable = lib.mkEnableOption "GitHub";
    style.colors.kanagawa.enable = lib.mkEnableOption "Kanagawa";
    style.colors.gruvbox-light.enable = lib.mkEnableOption "Gruvbox Light";
    style.colors.gruvbox-dark.enable = lib.mkEnableOption "Gruvbox Dark";
  };

  config = lib.mkMerge (
    lib.attrValues (lib.mapAttrs theme simpleThemes) ++
    [
    ]
    );
}
