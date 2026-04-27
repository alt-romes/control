# https://github.com/charmbracelet/crush
{ config, lib, inputs, ... }:
{
  imports = [
    inputs.nur-charmbracelet.homeModules.crush
  ];

  programs.crush = {
    enable = true;
    settings = {
      providers = {
        lm-studio = {
          id = "lm-studio";
          name = "LM Studio";
          base_url = "http://127.0.0.1:8012/v1";
          type = "openai";
          api_key = "irrelevant";
          models = [
            {
              id = "google/gemma-4-31b";
              name = "Gemma 4";
            }
          ];
        };
      };
      lsp = {
      };
      options = {
        context_paths = [ "/Users/romes/control/nix/home/romes.nix" ];
        tui = { compact_mode = true; };
        debug = false;
      };
    };
  };
}
