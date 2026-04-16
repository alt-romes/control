{ config, lib, pkgs, inputs, minimal, ... }:
{

  imports = [ inputs.nixvim.homeModules.nixvim ];

  programs.nixvim = {
    # use nixvim pkgs == home-manager pkgs == nixos nixpkgs
    # Not always a win since we may diverge from what is tested upstream and
    # run into new issues, but allows us to re-use the same pkgs (more
    # consistent) and share configs like allowUnfree. See
    # https://github.com/nix-community/nixvim/issues/2147
    nixpkgs.useGlobalPackages = true;

    enable = true;
    viAlias = true;
    vimAlias = true;

    # Color management done via the colors module in romes.nix

    opts = {
      # Options from https://github.com/alt-romes/.vim
      number=true; relativenumber=true;               # Set relative numbered lines
      expandtab=true; tabstop=4; shiftwidth=4;        # Indent by 4 spaces
      hlsearch=true; ignorecase=true; incsearch=true; # Highlight case-insensitive search while typing
      wildmenu=true;                                  # Display command-line completion menu
      mouse="a";                                      # Enable all mouse modes
      wrap=false; sidescroll=12; sidescrolloff=4;     # Disable line wrapping and set smoother horizontal scroll
      autoread=true;                                  # Automatically re-read files changed outside if not changed inside 
      modeline=true; modelines=4;                     # Check first and last file lines for modelines (that :set options)
      exrc=true; secure=true;                         # Read current directory .vimrc (with security-related limitations)
      spelllang="en_gb";                              # Spell languages to use when spell checking (:set spell)
      regexpengine=0;                                 # Automatically select regexp engine
      undofile=true; undodir="${config.home.homeDirectory}/.undofiles.vim";  # Persistent undo (:h persistent-undo)
      backspace="indent,eol,start";                   # Make backspace work as expected
      # set path+=** ??
      foldenable=false; foldmethod="marker";          # Fold with markers (e.g. set in a modeline to marker), open by default
      # termguicolors=true;
      conceallevel=2;                                 # Conceal level to hide typesetting details
      smartcase=true;                                 # Will use case-sensitive if capital or \C letter is present
      smarttab=true;                                  # Makes tabbing smarter will realize you have 2 vs 4, and default to tabstop/tabwidth when not obvious
      cursorline=true; cursorlineopt="both";          # Highlight the line number of the cursor line (cursorlineopt=number is also good)
      swapfile=true;                                  # We want swapfiles, and use vim's macOS default 'directory' option, which is within ~/Library
    };

    # Share clipboard between vim and system
    clipboard.register = "unnamedplus";

    files."ftplugin/nix.lua".opts = {
        tabstop=2; shiftwidth=2;
    };

    files."ftplugin/haskell.lua".opts = {
        tabstop=2; shiftwidth=2;
    };

    keymaps = [
      # Tag jumping
      { mode = "n"; key = "<C-j>"; action = "<C-]>"; }

      # Insert 80 `-` characters to make a line like:
      # --------------------------------------------
      { mode = "n"; key = "<leader>-"; action = ":normal 80i-<cr>"; }

      # Tree keymaps
      { mode = "n"; key = "<leader>t"; action = "<cmd>NvimTreeOpen<cr>"; }
      { mode = "n"; key = "<leader>o";
        # Open file selector in the directory of the current file
        action.__raw = "function() require(\"nvim-tree.api\").tree.open({ path = vim.fn.expand('%:p:h'), find_file = true }) end"; }

      # LSP Keymaps
      { mode = "n"; key = "<leader>a"; action = "<cmd>lua vim.lsp.buf.code_action()<cr>"; }
      { mode = "n"; key = "gd"; action = "<cmd>lua vim.lsp.buf.definition()<cr>"; }

      { # Remove all trailing whitespace
        mode = "n"; key = "<leader>w";
        action = ":let _s=@/ | %s/\\s\\+$//e | let @/=_s<CR>";
        options = { noremap = true; silent = true; };
      }

      # Quickfix and location list navigation
      { mode = "n"; key = "<leader>qo"; action = "<cmd>copen<cr>"; }
      { mode = "n"; key = "<leader>qn"; action = "<cmd>cnext<cr>"; }
      { mode = "n"; key = "<leader>qp"; action = "<cmd>cprev<cr>"; }
      { mode = "n"; key = "<leader>lo"; action = "<cmd>lopen<cr>"; }
      { mode = "n"; key = "<leader>ln"; action = "<cmd>lnext<cr>"; }
      { mode = "n"; key = "<leader>lp"; action = "<cmd>lprev<cr>"; }

      # DAP keymaps
      { mode = "n"; key = "<leader>dd"; action = "<cmd>DapNew<cr>"; }
      { mode = "n"; key = "<leader>dN"; action = "<cmd>DapNew<cr>"; }
      { mode = "n"; key = "<leader>dc"; action.__raw = "function() require('dap').continue() end"; }
      { mode = "n"; key = "<leader>dn"; action.__raw = "function() require('dap').step_over() end"; }
      { mode = "n"; key = "<leader>di"; action.__raw = "function() require('dap').step_into() end"; }
      { mode = "n"; key = "<leader>do"; action.__raw = "function() require('dap').step_out() end"; }
      { mode = "n"; key = "<leader>db"; action.__raw = "function() require('dap').toggle_breakpoint() end"; }
      { mode = "n"; key = "<leader>dB"; action.__raw = "function() require('dap').set_breakpoint() end"; }
      { mode = "n"; key = "<leader>dl"; action.__raw = "function() require('dap').set_breakpoint(nil, nil, vim.fn.input('Log point message: ')) end"; }
      { mode = "n"; key = "<leader>de"; action = "<cmd>DapEval<cr>"; }
      { mode = "n"; key = "<leader>dr"; action.__raw = "function() require('dap').repl.open() end"; }
      { mode = "n"; key = "<leader>dR"; action.__raw = "function() require('dap').restart() end"; }
      { mode = "n"; key = "<leader>dq"; action.__raw = "function() require('dap').terminate() end"; }
      { mode = "n"; key = "<leader>dw"; action.__raw = "function() require('dapui').elements.watches.add() end"; }
      { mode = ["n" "v"]; key = "<leader>dh"; action.__raw = "function() require('dap.ui.widgets').hover() end"; }
      { mode = ["n" "v"]; key = "<leader>dp"; action.__raw = "function() require('dap.ui.widgets').preview() end"; }

      # Hoogle
      {
        mode = "n";
        key = "<leader>h";
        action.__raw = ''
          function()
            local fzf = require("fzf-lua")
            fzf.fzf_live(function(args)
              local query = args[1]
              if not query or query == "" then
                return {}
              end
              return vim.fn.systemlist(
                "hoogle search --count=50 --link " .. vim.fn.shellescape(query)
              )
            end, {
              prompt = "Hoogle> ",
              exec_empty_query = false,
              actions = {
                ["default"] = function(selected)
                  if not selected or not selected[1] then return end
                  local url = selected[1]:match("%-%- (https?://%S+)$")
                  if url then
                    _G.open_url(url)
                  else
                    vim.notify(selected[1], vim.log.levels.INFO)
                  end
                end,
              },
            })
          end
        '';
      }
    ];

    userCommands = {
      Format = {
        command.__raw = ''
          function(args)
            local range = nil
            if args.count ~= -1 then
              local end_line = vim.api.nvim_buf_get_lines(0, args.line2 - 1, args.line2, true)[1]
                range = {
                  start = { args.line1, 0 },
                  ["end"] = { args.line2, end_line:len() },
                }
            end
            require("conform").format({ async = true, lsp_format = "fallback", range = range })
          end
          '';
        range = true;
      };
    };

    # Use <leader>oa for agenda actions (like oam to match tags)
    # Use <leader>oc for capture actions
    plugins.orgmode =
    let orgdir = "~/control/orgfiles";
        # Note: the iCloud folder should be configured to "Keep Downloaded" (right click to set)
        # OTOH, referenced files should go in orgfiles_docs, which shouldn't be kept downloaded.
        orgdir_icloud = "~/Library/Mobile\\ Documents/com\\~apple\\~CloudDocs/orgfiles";
    in
    {
      enable = true;
      settings = {
        org_agenda_files = [ "${orgdir}/**/*" "${orgdir_icloud}/**/*" ];
        org_default_notes_file = "${orgdir}/refile.org";
        org_capture_templates = {
          t = {
            description = "Todo";
            template = "* TODO %?\n  %U\n  %a";
            target = "${orgdir}/gtd.org";
            headline = "Inbox";
          };
          n = {
            description = "New note";
            template = "#+title: %^{Title}\n#+date: %U\n\n%?";
            target = "${orgdir}/notes/%<%Y-%m-%d-%H%M>.org";
          };
          j = {
            description = "Journal";
            template = "* %?\nEntered on %U\n  %a";
            target = "${orgdir}/journal.org";
            datetree = true;
          };
          ii = {
            description = "New note (iCloud)";
            template = "#+title: %^{Title}\n#+date: %U\n\n%?";
            target = "${orgdir_icloud}/notes/%<%Y-%m-%d-%H%M>.org";
          };
          ij = {
            description = "Journal (iCloud)";
            template = "* %?\nEntered on %U\n  %a";
            target = "${orgdir_icloud}/journal.org";
            datetree = true;
          };
        };
      };
    };

    /* Language Server Protocols */
    plugins.lsp = {
        enable = true;
        servers = {
          # Haskell
          hls = {
            enable = true;
            installGhc = false; # Disable a warning for ghc installation
          };

          # Nix
          nixd.enable = !minimal;

          # Swift
          sourcekit.enable = false;
        };
    };

    /* Plugins */
    plugins.treesitter.enable = !minimal; # too slow for VM, too many languages supported.

    # Telescope is too slow to find files, so we use fzf-lua there.
    plugins.telescope.enable = true;
    plugins.telescope.extensions.fzf-native.enable = true;
    plugins.fzf-lua.enable = true;
    plugins.fzf-lua.keymaps = {
      "<leader>f" = "files";
      "<leader>g" = "live_grep";
      "<leader>b" = "builtin";
    };
    plugins.fzf-lua.settings.winopts.backdrop = 100;
    plugins.fzf-lua.settings.winopts.fullscreen = true;
    plugins.web-devicons.enable = true; # required by telescope

    plugins.nvim-surround.enable = true;
    plugins.fugitive.enable = true;
    plugins.emmet.enable = true;

    plugins.nvim-tree = {
      enable = true;
      settings = { disable_netrw = true; };
      openOnSetup = true;
    };

    plugins.oil.enable = true;

    # For .journal files (hledger)
    plugins.ledger = {
      enable = true;
      settings = {
        bin = "${pkgs.hledger}/bin/hledger";
        is_hledger = true;
      };
    };

    /* DAP */
    plugins.dap = {
      enable = true;

      adapters.servers = {
        haskell-debugger = {
          port = "\${port}";

          # Launch this server automatically for each launch
          executable = {
            command = "hdb";
            args = ["server" "--port" "\${port}"];
          };
        };
      };

      configurations = {
        haskell = [
          {
            type = "haskell-debugger";
            request = "launch";
            name = "hdb:file:main";
            entryFile = "\${file}";
            entryPoint = "main";
            projectRoot = "\${workspaceFolder}";
            entryArgs = [];
            extraGhcArgs = [];
          }
        ];
      };
    };
    /* Better debugger UI on top of nvim-dap which is insufficient */
    /* 
    Bugs:
      - the terminal doesn't appear the first time the window is shown for some reason
      - expanding an IO value which doesn't return anything results in duplication...
    Is this mine or nvim-dap's bug? Investigate what's being returned when an
    IO action is forced.
    */
    plugins.dap-view = {
      enable = true;
      settings = {
        auto_toggle = true;
        winbar = {
          sections = [ "console" "repl" "threads" "scopes" "watches" "exceptions" "breakpoints" "sessions" ];
          default_section = "repl";
          base_sections = {
            scopes = { label = "Variables"; keymap = "V"; };
          };
        };
        windows = {
          size = 0.3;
          position = "below";
        };
      };
    };

    plugins.copilot-vim = {
      enable = true; # experimenting...
      # ^ super annoying when you run out of tokens.
      # much prefer the local llama.cpp version.

      # disabled by default. Use :Copilot enable
      settings.enabled = false;
    };

    plugins.lean.enable = false;

    # Formatters
    plugins.conform-nvim = {
      enable = true;
      settings = {
        formatters_by_ft = {
          haskell = [ "stylish-haskell" ];
          "_" = [
            "trim_whitespace"
            "trim_newlines"
          ];
        };
        log_level = "warn";
        notify_on_error = false;
        notify_no_formatters = false;
        formatters = {
          stylish-haskell = {
            command = lib.getExe pkgs.stylish-haskell;
          };
        };
      };
    };

    /* Extra Plugins */
    extraPlugins = [
      (pkgs.vimUtils.buildVimPlugin {
        name = "linediff.vim";
        src = pkgs.fetchFromGitHub {
            owner = "AndrewRadev";
            repo = "linediff.vim";
            rev = "ddae71ef5f94775d101c1c70032ebe8799f32745";
            hash = "sha256-ZyQzLpzvS887J1Gdxv1edC9MhPj1EEITh27rUPuFugU=";
        };
      })

      pkgs.vimPlugins.llama-vim
    ];

    extraPackages = [
      pkgs.haskellPackages.hoogle
    ];

    # Enable with :LlamaEnable
    # show_info = 0,
    extraConfigLua = ''
      vim.g.llama_config = {
        enable_at_startup = false,
        endpoint = "http://127.0.0.1:8012/v1/completions"
      }

      function _G.open_url(url)
        if vim.ui.open then
          local _, err = vim.ui.open(url)
          if not err then
            return
          end
        end

        local opener = vim.fn.has("mac") == 1 and "open"
          or vim.fn.executable("xdg-open") == 1 and "xdg-open"
          or nil

        if not opener then
          vim.notify("No URL opener found", vim.log.levels.ERROR)
          return
        end

        vim.fn.jobstart({ opener, url }, { detach = true })
      end
    '';

    extraConfigVim = ''
      digraph -o 8888
      digraph cp 215
    '';
  };

}
