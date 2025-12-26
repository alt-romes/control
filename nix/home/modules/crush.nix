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
          base_url = "http://127.0.0.1:2222";
          type = "openai";
          api_key = "irrelevant";
          models = [
            # Run with:
            # /opt/homebrew/bin/llama-server -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL --jinja -ngl 99 --threads -1 --ctx-size 32684 --temp 0.7 --min-p 0.0 --top-p 0.80 --top-k 20 --repeat-penalty 1.05 --host 127.0.0.1 --port 2222 --no-slots --timeout 600
            {
              id = "qwen3:30b";
              name = "Qwen 3 30B";
              context_window = 32000;
              default_max_tokens = 20000;
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
