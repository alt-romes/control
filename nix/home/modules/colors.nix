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
    style.colors.everforest.enable = lib.mkEnableOption "Everforest dark hard";
    style.colors.oxocarbon.enable = lib.mkEnableOption "Oxocarbon dark";
    # style.colors.ayu.enable = lib.mkEnableOption "Ayu light";

    style.colors.base16.enable = lib.mkEnableOption "Base16 colorscheme using nix-colors";
    style.colors.base16.colorScheme = lib.mkOption {
      type = lib.types.attrs;
      example = ''
        Should be set to a nix-colors color scheme.
        This can either be generated from a picture:

          inputs.nix-colors.colorSchemeFromPicture { path = ...; variant = ...; }

        or a predefined color scheme:

          inputs.nix-colors.colorSchemes.paraiso

        or a custom color scheme:

          see https://github.com/Misterio77/nix-colors
      '';
    };
    # nix-colors.colorSchemeFromPicture { inherit pkgs; } { path = ...; variant = ...; };
  };

  config = lib.mkMerge (
    lib.attrValues (lib.mapAttrs theme simpleThemes) ++
    [
      # Base 16 colorscheme
      (lib.mkIf config.style.colors.base16.enable {

        # Doesn't work well, the "setup with these colors".
        # programs.nixvim.colorschemes.base16.enable = true;
        # programs.nixvim.colorschemes.base16.colorscheme =
        #   lib.mapAttrs (_: color: "#${color}")
        #     config.style.colors.base16.colorScheme.palette;

        programs.ghostty.settings.theme = config.style.colors.base16.colorScheme.slug;
        programs.ghostty.themes.${config.style.colors.base16.colorScheme.slug} =
        let palette = config.style.colors.base16.colorScheme.palette;
        in {
          cursor-color = "${palette.base05}";
          background = "${palette.base00}";
          foreground = "${palette.base05}";
          selection-background = "${palette.base02}";
          selection-foreground = "${palette.base00}";
          palette = [
            "0=#${palette.base00}"
            "1=#${palette.base01}"
            "2=#${palette.base02}"
            "3=#${palette.base03}"
            "4=#${palette.base04}"
            "5=#${palette.base05}"
            "6=#${palette.base06}"
            "7=#${palette.base07}"
            "8=#${palette.base08}"
            "9=#${palette.base09}"
            "10=#${palette.base0A}"
            "11=#${palette.base0B}"
            "12=#${palette.base0C}"
            "13=#${palette.base0D}"
            "14=#${palette.base0E}"
            "15=#${palette.base0F}"
          ];
        };

      })
    ]
    );
}
