{
  flake.homeModules.colors = { config, lib, pkgs, ... }:
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
          ghostty = "Everforest Dark Hard";
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
          tmux = "kanagawa";
        };
        gruvbox-light = {
          vim = "gruvbox";
          background = "light";
          ghostty = "Gruvbox Light";
          tmux = "gruvbox";
        };
        gruvbox-dark = {
          vim = "gruvbox";
          background = "dark";
          ghostty = "Gruvbox Dark";
          tmux = "gruvbox";
        };
        catppuccin = {
          vim = "catppuccin";
          vim-colorscheme = "catppuccin-mocha";
          background = "dark";
          ghostty = "Catppuccin Mocha";
          tmux = "catppuccin";
        };
        tokyonight = {
          vim = "tokyonight";
          vim-colorscheme = "tokyonight-night";
          background = "dark";
          ghostty = "TokyoNight Night";
          tmux = "tokyo-night-tmux";
        };
        rose-pine = {
          vim = "rose-pine";
          background = "dark";
          ghostty = "Rose Pine";
          tmux = "rose-pine";
        };
        nord = {
          vim = "nord";
          background = "dark";
          ghostty = "Nord";
          tmux = "nord";
        };
        catppuccin-latte = {
          vim = "catppuccin";
          vim-colorscheme = "catppuccin-latte";
          background = "light";
          ghostty = "Catppuccin Latte";
          tmux = "catppuccin";
        };
        rose-pine-dawn = {
          vim = "rose-pine";
          vim-colorscheme = "rose-pine-dawn";
          background = "light";
          ghostty = "Rose Pine Dawn";
          tmux = "rose-pine";
        };
        tokyonight-day = {
          vim = "tokyonight";
          vim-colorscheme = "tokyonight-day";
          background = "light";
          ghostty = "TokyoNight Day";
          tmux = "tokyo-night-tmux";
        };
        everforest-light = {
          vim = "everforest";
          ghostty = "Everforest Light Med";
          background = "light";
        };
        github-light-high-contrast = {
          vim = "github-theme";
          vim-colorscheme = "github_light_high_contrast";
          background = "light";
          ghostty = "GitHub Light High Contrast";
        };
        kanagawa-lotus = {
          vim = "kanagawa";
          vim-colorscheme = "kanagawa-lotus";
          background = "light";
          ghostty = "Kanagawa Lotus";
          tmux = "kanagawa";
        };
        dayfox = {
          vim = "nightfox";
          vim-colorscheme = "dayfox";
          background = "light";
          ghostty = "Dayfox";
        };
        dawnfox = {
          vim = "nightfox";
          vim-colorscheme = "dawnfox";
          background = "light";
          ghostty = "Dawnfox";
        };
        melange-light = {
          vim = "melange";
          background = "light";
          ghostty = "Melange Light";
        };
        modus-operandi = {
          vim = "modus";
          background = "light";
          ghostty = "Modus Operandi";
        };
        gruvbox-material-light = {
          vim = "gruvbox-material";
          background = "light";
          ghostty = "Gruvbox Material Light";
        };
        nord-light = {
          vim = "nord";
          background = "light";
          ghostty = "Nord Light";
          tmux = "nord";
        };
      };

      theme = themeName: themeConf:
        let base = {
              programs.ghostty.settings.theme = themeConf.ghostty;
              programs.nixvim.opts.background = themeConf.background; # "light" or "dark"
            };
            vim1 = if themeConf ? vim then {
              programs.nixvim.colorschemes.${themeConf.vim}.enable = true;
            } else {};
            vim2 = if themeConf ? vim-colorscheme then {
              programs.nixvim.colorscheme = themeConf.vim-colorscheme;
            } else {};
            tmux = if themeConf ? tmux then {
              programs.tmux.plugins = [ pkgs.tmuxPlugins.${themeConf.tmux} ];
            } else {};
            extra = if themeConf ? extraSettings then themeConf.extraSettings else {};
        in lib.mkIf (config.style.colors.theme == themeName)
             (lib.foldl' lib.recursiveUpdate base [ vim1 vim2 tmux extra ]);
    in
    {

      options.style.colors.theme = lib.mkOption {
        type = lib.types.enum (lib.attrNames simpleThemes);
        description = "Color theme name";
      };

      config = lib.mkMerge (
        lib.attrValues (lib.mapAttrs theme simpleThemes) ++
        [
        ]
        );
    };
}
