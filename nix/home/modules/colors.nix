{
  flake.homeModules.colors = { config, lib, pkgs, ... }:
    let
      simpleThemes = {
        oxocarbon = {
          vim = "oxocarbon";
          ghostty = "oxocarbon";
          background = "dark";
          lightline = "default";
        };
        ayu-light = {
          vim = "ayu";
          background = "light";
          ghostty = "Ayu Light";
          lightline = "ayu_light";
        };
        ayu-dark = {
          vim = "ayu";
          background = "dark";
          ghostty = "Ayu";
          lightline = "ayu_dark";
        };
        everforest = {
          vim = "everforest";
          ghostty = "Everforest Dark Hard";
          background = "dark";
          lightline = "everforest";
          extraSettings = {
            programs.nixvim.colorschemes.everforest.settings.background = "hard";
          };
        };
        hotblue = {
          vim-colorscheme = "blue";
          background = "dark";
          ghostty = "Hot Dog Stand";
          lightline = "default";
        };
        github = {
          vim = "github-theme";
          vim-colorscheme = "github_light_default";
          background = "light";
          ghostty = "GitHub";
          lightline = "github";
        };
        kanagawa = {
          vim = "kanagawa";
          vim-colorscheme = "kanagawa-dragon";
          background = "dark";
          ghostty = "Kanagawa Dragon";
          tmux = "kanagawa/dragon";
          lightline = "kanagawa";
        };
        gruvbox-light = {
          vim = "gruvbox";
          background = "light";
          ghostty = "Gruvbox Light";
          tmux = "gruvbox/light";
          lightline = "gruvbox";
        };
        gruvbox-dark = {
          vim = "gruvbox";
          background = "dark";
          ghostty = "Gruvbox Dark";
          tmux = "gruvbox/dark";
          lightline = "gruvbox";
        };
        catppuccin = {
          vim = "catppuccin";
          vim-colorscheme = "catppuccin-mocha";
          background = "dark";
          ghostty = "Catppuccin Mocha";
          tmux = "catppuccin/mocha";
          lightline = "catppuccin";
        };
        tokyonight = {
          vim = "tokyonight";
          vim-colorscheme = "tokyonight-night";
          background = "dark";
          ghostty = "TokyoNight Night";
          tmux = "tokyonight/night";
          lightline = "tokyonight";
        };
        rose-pine = {
          vim = "rose-pine";
          background = "dark";
          ghostty = "Rose Pine";
          tmux = "rose-pine/main";
          lightline = "rosepine";
        };
        nord = {
          vim = "nord";
          background = "dark";
          ghostty = "Nord";
          tmux = "nord/default";
          lightline = "nord";
        };
        catppuccin-latte = {
          vim = "catppuccin";
          vim-colorscheme = "catppuccin-latte";
          background = "light";
          ghostty = "Catppuccin Latte";
          lightline = "catppuccin";
        };
        rose-pine-dawn = {
          vim = "rose-pine";
          vim-colorscheme = "rose-pine-dawn";
          background = "light";
          ghostty = "Rose Pine Dawn";
          tmux = "rose-pine/dawn";
          lightline = "rosepine_dawn";
        };
        tokyonight-day = {
          vim = "tokyonight";
          vim-colorscheme = "tokyonight-day";
          background = "light";
          ghostty = "TokyoNight Day";
          lightline = "tokyonight";
        };
        everforest-light = {
          vim = "everforest";
          ghostty = "Everforest Light Med";
          background = "light";
          lightline = "everforest";
        };
        github-light-high-contrast = {
          vim = "github-theme";
          vim-colorscheme = "github_light_high_contrast";
          background = "light";
          ghostty = "GitHub Light High Contrast";
          lightline = "github";
        };
        kanagawa-lotus = {
          vim = "kanagawa";
          vim-colorscheme = "kanagawa-lotus";
          background = "light";
          ghostty = "Kanagawa Lotus";
          tmux = "kanagawa/lotus";
          lightline = "kanagawa";
        };
        dayfox = {
          vim = "nightfox";
          vim-colorscheme = "dayfox";
          background = "light";
          ghostty = "Dayfox";
          lightline = "nightfox";
        };
        dawnfox = {
          vim = "nightfox";
          vim-colorscheme = "dawnfox";
          background = "light";
          ghostty = "Dawnfox";
          lightline = "nightfox";
        };
        melange-light = {
          vim = "melange";
          background = "light";
          ghostty = "Melange Light";
          lightline = "melange";
        };
        modus-operandi = {
          vim = "modus";
          background = "light";
          ghostty = "Modus Operandi";
          lightline = "modus_operandi";
        };
        gruvbox-material-light = {
          vim = "gruvbox-material";
          background = "light";
          ghostty = "Gruvbox Material Light";
          lightline = "gruvbox_material";
        };
        nord-light = {
          vim = "nord";
          background = "light";
          ghostty = "Nord Light";
          lightline = "nord";
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
            lightline = if themeConf ? lightline then {
              programs.nixvim.plugins.lightline.settings.colorscheme = themeConf.lightline;
            } else {};
            tmux = if themeConf ? tmux then {
              programs.tmux.plugins = [ {
                plugin = pkgs.tmuxPlugins.ukiyo;
                extraConfig = ''set -g @ukiyo-theme "${themeConf.tmux}"'';
              } ];
            } else {};
            extra = if themeConf ? extraSettings then themeConf.extraSettings else {};
        in lib.mkIf (config.style.colors.theme == themeName)
             (lib.foldl' lib.recursiveUpdate base [ vim1 vim2 lightline tmux extra ]);
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
