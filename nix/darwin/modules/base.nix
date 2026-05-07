{ self, inputs, ... }:
{
  flake.darwinModules.base = { pkgs, ... }: {

    nixpkgs.hostPlatform = "aarch64-darwin";
    nixpkgs.config.allowUnfree = true;

    # Used for backwards compatibility, please read the changelog before changing.
    # $ darwin-rebuild changelog
    system.stateVersion = 5;

    modules = [
      inputs.home-manager.darwinModules.home-manager
      inputs.agenix.darwinModules.default

      self.darwinModules.linux-builder
      self.darwinModules.caddy # Localhost reverse proxy
    ];

    nix.settings = {

      # Necessary for using flakes on this system.
      experimental-features = [ "nix-command" "flakes" ];

      trusted-users = [ "root" "romes" "@admin" ];

      # Apple virtualization for linux builder
      system-features = [ "nixos-test" "apple-virt" ];
    };

    system.primaryUser = "romes";

    homebrew = {
      # this doesn't install homebrew, needs to be installed manually (see instructions on website)
      enable = true;

      brews = [ # non-cask formulaes
      ];
      casks = [ # casks, see also per-machine configuration (see relevant files)
        "flycut"
        "ghostty"
        "anki"
        "firefox"
        "mattermost"
        "skim"
        "visual-studio-code" # experimenting debugger
        "discord"
        "affinity-designer"
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
      onActivation.upgrade = true;
    };

    programs._1password.enable = true; # 1Password CLI

    environment = {
      systemPackages = [
        pkgs.vim
      ];

      variables = {
        HISTCONTROL = "ignoredups";
        EDITOR = "vim";
      };

      shellAliases = {
        # submodules=1 is needed because some modules of the system are in git submodules (such as finances.nix)
        darwin-nix-switch = "sudo darwin-rebuild switch --flake '/Users/romes/control/.?submodules=1'";
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
      pkgs.noto-fonts-cjk-sans
      pkgs.noto-fonts-cjk-serif

      pkgs.ioskeley-mono.normal
    ];

    users.users."romes" = {
      name = "romes";
      home = "/Users/romes";
      shell = pkgs.zsh; # zsh shell; configured in home/romes
      isHidden = false;

      # Connect over SSH
      # NOTE: Requires manually setting General > Sharing > Remote Login ON to activate remote login
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ"
      ];
    };

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

    security.pam.services.sudo_local.touchIdAuth = true; # enable touch id for sudo

    # ------------------------------------------------------------------------
    # Home Manager

    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.romes = {
      imports = [
        self.homeModules.romes
      ];
    };
  };
}
