{
  flake.homeModules.fonts = { config, lib, pkgs, ... }:
    let
      simpleFonts = {
        ioskeley = {
          ghostty = "Ioskeley Mono";
          package = pkgs.ioskeley-mono.normal;
        };
        iosevka = {
          ghostty = "IosevkaTerm Nerd Font Mono";
          package = pkgs.nerd-fonts.iosevka-term;
        };
        maple-mono = {
          ghostty = "Maple Mono NF";
          package = pkgs.maple-mono.NF;
        };
        jetbrains-mono = {
          ghostty = "JetBrains Mono";
          package = pkgs.nerd-fonts.jetbrains-mono;
        };
        fira-code = {
          ghostty = "Fira Code";
          package = pkgs.fira-code;
        };
      };

      font = fontName: fontConf:
        lib.mkIf (config.style.fonts.font == fontName) {
          home.packages = [ fontConf.package ];
          programs.ghostty.settings.font-family = fontConf.ghostty;
        };
    in
    {
      options.style.fonts.font = lib.mkOption {
        type = lib.types.enum (lib.attrNames simpleFonts);
        description = "Monospace font name";
      };

      config = lib.mkMerge (lib.attrValues (lib.mapAttrs font simpleFonts));
    };
}
