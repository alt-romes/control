{ self, inputs, ... }:
{
  flake.darwinModules.base = { pkgs, ... }: {

    imports = [
      inputs.home-manager.darwinModules.home-manager
      self.darwinModules.agenix
      self.darwinModules.linux-builder
      self.darwinModules.caddy # Localhost reverse proxy
      self.darwinModules.dashboards
    ];

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

        # fonts
        "font-space-grotesk" # Space Grotesk (btw mogbit logo uses it)
      ];

      # Manage brew formulae using nix only:
      # Pass --cleanup --zap to bundle, so everything not referenced is uninstalled.
      onActivation.cleanup = "zap";

      # Homebrew >=5.1 refuses `brew bundle --cleanup` non-interactively unless
      # one of --force/--force-cleanup/$HOMEBREW_ASK is given. nix-darwin doesn't
      # pass any, so add --force-cleanup (forces only the cleanup, not install
      # --overwrite) to keep activation non-interactive.
      onActivation.extraFlags = [ "--force-cleanup" ];

      # Update brew packages on activation. No point in trying to have
      # reproducibility / idempotence of brew formulas and casks, as they're not
      # pinned in any meaningful way. This applies mostly to Casks anyway :)
      onActivation.autoUpdate = true;
      onActivation.upgrade = true;

      # List below things to get from App Store:
      # 1Password (maybe not from App Store?)
      # Things
      # DaisyDisk
      # Logic Pro
      # Final Cut Pro
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
    ];

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
    # Secrets

    age.secrets.kimai = {
      file = ./_agenix/kimai.age;
      owner = "romes";
    };

    # ------------------------------------------------------------------------
    # Users & Home Manager

    system.primaryUser = "romes";

    users.users."romes" = {
      name = "romes";
      home = "/Users/romes";
      shell = pkgs.zsh;
      isHidden = false;

      # NOTE: Requires manually setting General > Sharing > Remote Login ON to activate remote login
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLE1i0MvrzHQuGhOi90vXuZFoMjQ1EtP86tjE4HVB2vJG7QMJk4uivKfY503DGUvcvBsEH6JWYUCttcNGckO4R8=" # Macmini key iPhone Termius
      ];
    };

    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.romes = {
      imports = [
        self.homeModules.romes
      ];
    };

    # ------------------------------------------------------------------------
    # Meta

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" "romes" "@admin" ];
      system-features = [ "nixos-test" "apple-virt" ];
        # ^ Apple virtualization for linux builder
    };

    # TODO: Needed?
    # nixpkgs.overlays = [ inputs.claude-code-nix.overlays.default ];

    nixpkgs.hostPlatform = "aarch64-darwin";
    nixpkgs.config.allowUnfree = true;

    # Used for backwards compatibility, please read the changelog before changing.
    # $ darwin-rebuild changelog
    system.stateVersion = 5;

  };
}
