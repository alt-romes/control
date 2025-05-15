{ pkgs, lib, config, inputs, system, configurationRevision, ... }: {

  # -- System Meta -------------------------------------------------------------

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 5;
  system.configurationRevision = configurationRevision;
  nixpkgs.hostPlatform = system;
  # VSCode marketplace overlay
  # nixpkgs.overlays = [ inputs.nix-vscode-extensions.overlays.default ];

  # ----------------------------------------------------------------------------

  imports = [
    # Home-manager
    inputs.home-manager.darwinModules.home-manager

    # Agenix
    inputs.agenix.darwinModules.default

    # Linux Builder (custom)
    ./modules/linux-builder.nix

    # Finances (custom)
    ../../finances/finances.nix
  ];

  nix.settings = {

    # Necessary for using flakes on this system.
    experimental-features = [ "nix-command" "flakes" ];

    trusted-users = [ "root" "romes" "@admin" ];

    # Apple virtualization for linux builder
    system-features = [ "nixos-test" "apple-virt" ];
  };

  homebrew = {
    # this doesn't install homebrew, needs to be installed manually (see instructions on website)
    enable = true;

    brews = []; # non-cask formulaes, per-machine configuration (see relevant files)
    casks = [ # casks, see also per-machine configuration (see relevant files)
      "flycut"
      "ghostty"
      "anki"
      "firefox"
      "vlc"
      "mattermost"
      "skim"
      "visual-studio-code" # experimenting debugger and agents
      "discord"
    ];

    # command line for Mac App Store. Not using this (ie `mas`) yet.
    # List below things to get from App Store:
    masApps = {
      # 1Password (maybe not from App Store?)
      # 1Password for Safari
      # Things
      # DaisyDisk
      # Logic Pro
      # Final Cut Pro
    };

    # Manage brew formulae using nix only
    # Pass --cleanup --zap to bundle, so everything not referenced is uninstalled.
    onActivation.cleanup = "zap";

    # Update brew packages on activation. No point in trying to have
    # reproducibility / idempotence of brew formulas and casks, as they're not
    # pinned in any meaningful way. This applies mostly to Casks anyway :)
    onActivation.autoUpdate = true;
  };

  # 1Password CLI
  programs._1password.enable = true;

  environment = {
    # List packages installed in system profile. To search by name, run:
    # $ nix-env -qaP | grep wget
    systemPackages = [
      pkgs.vim
      pkgs.eza           # ls replacement

      # Commonly needed in the env for building code
      # NOTE: Use .dev output to guarantee correct paths to libs et all.
      pkgs.zlib pkgs.gmp pkgs.zlib.dev pkgs.gmp.dev
    ];

    variables = {
      HISTCONTROL = "ignoredups";
      EDITOR = "vim";
    };

    shellAliases = {
      mv = "mv -i";
      cp = "cp -i";
      ls = "eza";

      g = "git";
      httpserver = "nix-shell -p python3 --run 'python -m http.server 25565'";
      darwin-nix-switch = "darwin-rebuild switch --flake '/Users/romes/control/nix/.?submodules=1'"; # submodules=1 is needed because some modules of the system are in git submodules (such as finances.nix)
      # ghc-nix = "nix develop git+https://gitlab.haskell.org/ghc/ghc.nix";
      ghc-nix = "nix-shell -p haskell.compiler.ghc910 haskellPackages.alex haskellPackages.happy autoconf automake python3 gmp zlib";
    };

    # Write additional options for sshd_config
    # to disable password and interactive authentication
    etc."ssh/sshd_config.d/100-romes-nopassword".text = ''
      KbdInteractiveAuthentication no
      PasswordAuthentication no
    '';

    # Add zsh to /etc/shells
    shells = [ pkgs.zsh ];
    # and add more zsh autocompletions as said in the home-manager docs
    pathsToLink = [ "/usr/share/zsh" ];

  };

  fonts.packages = [
    pkgs.noto-fonts
  ];

  users.users."romes" = {
    name = "romes";
    home = "/Users/romes";
    shell = pkgs.zsh; # zsh shell; configured in home/romes

    # Connect over SSH
    # NOTE: Requires manually setting General > Sharing > Remote Login ON to activate remote login
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ"
    ];
  };

  security.pam.services.sudo_local.touchIdAuth = true; # enable touch id for sudo

  system.defaults = {
    dock = {

      # Autohide dock
      autohide = true;

      # Hot Corners!
      wvous-bl-corner = 4; # bottom left = Desktop
      wvous-br-corner = 3; # bottom right = Application Windows
      wvous-tl-corner = 2; # top left = Mission Control
      wvous-tr-corner = 12; # top right = Notification Center
    };
  };

  # ------------------------------------------------------------------------
  # Home Manager
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.romes = import ../home/romes.nix;
  home-manager.extraSpecialArgs = {
    inherit inputs system;
    # osConfig is inherited and points to the NixOS configuration
  };

  # ------------------------------------------------------------------------
  # Agenix secrets

  # While SSH_AUTH_SOCKET doesn't work, we need to download from 1Password the
  # key into this path to decrypt the secrets.
  # See https://github.com/ryantm/agenix/issues/182
  # once this made the switch fail; but re-running fixed it... it looked like a
  # race where the identity key wasn't ready yet.
  age.identityPaths = [ "/Users/romes/.ssh/agenix" ];
  age.secrets.kimai = {
    file = ../../secrets/kimai.age;
    # this secret will be accessed on home-manager activation and when used as a tool
    # so the user needs permissions
    owner = "romes";
  };

  # ------------------------------------------------------------------------
  # Custom modules options

  # Finances management
  finances = {
    enable = true;
    all.ledger = "/Users/romes/control/finances/all.journal";
    personal.ledger = "/Users/romes/control/finances/2025.journal";
    mogbit.ledger = "/Users/romes/control/finances/mogbit/2025.journal";
    prices.ledger = "/Users/romes/control/finances/prices.journal";

    # Packages needed to build some of the finance utilities
    packages = {
      kimai = config.home-manager.users.romes.programs.kimai.package;
      run-things-url = (import ./shortcuts/shortcuts.nix { inherit pkgs lib; }).Run-Things-URL;
    };

    # Note: finances.daemons must be set per-machine depending on
    # whether the periodically scheduled launchd daemons are wanted
    # Currently, this is macmini = ON, mbp = OFF
  };

}
