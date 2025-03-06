{ pkgs, ... }: {

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

  # Enable alternative shell support in nix-darwin.
  # programs.fish.enable = true;

  environment = {
    # List packages installed in system profile. To search by name, run:
    # $ nix-env -qaP | grep wget
    systemPackages = [
      pkgs.vim
      pkgs.eza           # ls replacement
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
      darwin-nix-switch = "darwin-rebuild switch --flake '/Users/romes/control/nix/darwin/.?submodules=1'"; # submodules=1 is needed because some modules of the system are in git submodules (such as finances.nix)
      # ghc-nix = "nix develop git+https://gitlab.haskell.org/ghc/ghc.nix";
      ghc-nix = "nix-shell -p haskell.compiler.ghc910 haskellPackages.alex haskellPackages.happy autoconf automake python3 gmp";
    };
  };

  users.users."romes" = {
    name = "romes";
    home = "/Users/romes";
  };

  # Connect over SSH
  # NOTE: Requires manually setting General > Sharing > Remote Login ON to activate remote login
  users.users."romes".openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ"
  ];
  # Write additional options for sshd_config
  # to disable password and interactive authentication
  environment.etc."ssh/sshd_config.d/100-romes-nopassword".text = ''
    KbdInteractiveAuthentication no
    PasswordAuthentication no
  '';

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
  # Custom modules and options

  imports = [
    ./modules/linux-builder.nix
    ../../finances/finances.nix
  ];

  # Background linux VM runner process is off by default
  # and enabled per-machine.
  process.linux-builder.enable = false;

  # Finances management
  finances = {
    enable = true;
    all.ledger = "/Users/romes/control/finances/all.journal";
    personal.ledger = "/Users/romes/control/finances/2025.journal";
    mogbit.ledger = "/Users/romes/control/finances/mogbit/2025.journal";
    # Note: finances.daemons.enable must be set per-machine depending on
    # whether the periodically scheduled launchd daemons are wanted
    # Currently, this is macmini = ON, mbp = OFF
  };

}
