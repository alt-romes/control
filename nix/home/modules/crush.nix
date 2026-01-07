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
        llama-cpp = {
          id = "llama-cpp";
          name = "Llama.cpp";
          base_url = "http://127.0.0.1:8012";
          type = "openai";
          api_key = "irrelevant";
          models = [
            # Possibly: Run with:
            # /opt/homebrew/bin/llama-server -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL --jinja -ngl 99 --threads -1 --ctx-size 32684 --temp 0.7 --min-p 0.0 --top-p 0.80 --top-k 20 --repeat-penalty 1.05 --host 127.0.0.1 --port 2222 --no-slots --timeout 600
            {
              id = "qwen3:30b";
              name = "Qwen 3 30B";
            }
          ];
        };
        lm-studio = {
          id = "lm-studio";
          name = "LM Studio";
          base_url = "http://127.0.0.1:8012/v1";
          type = "openai";
          api_key = "irrelevant";
          models = [
            {
              id = "mistralai/devstral-small-2-2512";
              name = "Devstral Small 2 2512";
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
