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
        cascadia-code = {
          ghostty = "CaskaydiaMono Nerd Font";
          package = pkgs.nerd-fonts.caskaydia-mono;
        };
        victor-mono = {
          ghostty = "VictorMono Nerd Font";
          package = pkgs.nerd-fonts.victor-mono;
        };
        hack = {
          ghostty = "Hack Nerd Font";
          package = pkgs.nerd-fonts.hack;
        };
        commit-mono = {
          ghostty = "CommitMono Nerd Font";
          package = pkgs.nerd-fonts.commit-mono;
        };
        geist-mono = {
          ghostty = "GeistMono Nerd Font";
          package = pkgs.nerd-fonts.geist-mono;
        };
        geist-mono-plain = {
          ghostty = "Geist Mono";
          package = pkgs.geist-font;
        };
        zed-mono = {
          ghostty = "ZedMono Nerd Font";
          package = pkgs.nerd-fonts.zed-mono;
        };
        departure-mono = {
          ghostty = "DepartureMono Nerd Font";
          package = pkgs.nerd-fonts.departure-mono;
        };
        monaspace-neon = {
          ghostty = "Monaspace Neon";
          package = pkgs.monaspace;
        };
        monaspace-argon = {
          ghostty = "Monaspace Argon";
          package = pkgs.monaspace;
        };
        monaspace-krypton = {
          ghostty = "Monaspace Krypton";
          package = pkgs.monaspace;
        };
        monaspace-xenon = {
          ghostty = "Monaspace Xenon";
          package = pkgs.monaspace;
        };
        monaspace-radon = {
          ghostty = "Monaspace Radon";
          package = pkgs.monaspace;
        };
        intel-one-mono = {
          ghostty = "Intel One Mono";
          package = pkgs.intel-one-mono;
        };
        recursive-mono = {
          ghostty = "RecMonoCasual Nerd Font";
          package = pkgs.nerd-fonts.recursive-mono;
        };
        martian-mono = {
          ghostty = "MartianMono Nerd Font";
          package = pkgs.nerd-fonts.martian-mono;
        };
        mononoki = {
          ghostty = "Mononoki Nerd Font";
          package = pkgs.nerd-fonts.mononoki;
        };
        fantasque-sans-mono = {
          ghostty = "FantasqueSansM Nerd Font Mono";
          package = pkgs.nerd-fonts.fantasque-sans-mono;
        };
        lilex = {
          ghostty = "Lilex";
          package = pkgs.lilex;
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
