{
  description = "Romes Nix-Darwin, for MBP M2 and Mac Mini M4";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";
  };

outputs = inputs@{ self, nix-darwin, home-manager, nixvim, nixpkgs }:
let
  common =
    { pkgs, ... }: {
      # Used for backwards compatibility, please read the changelog before changing.
      # $ darwin-rebuild changelog
      system.stateVersion = 5;

      # Set Git commit hash for darwin-version.
      system.configurationRevision = self.rev or self.dirtyRev or null;

      # The platform the configuration will be used on.
      nixpkgs.hostPlatform = "aarch64-darwin";

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
      };

      # Enable alternative shell support in nix-darwin.
      # programs.fish.enable = true;

      environment = {
        # List packages installed in system profile. To search by name, run:
        # $ nix-env -qaP | grep wget
        systemPackages = [
          pkgs.vim
          pkgs.colmena       # deployment tool
          pkgs.nixos-rebuild # to deploy to remote nixos machines directly

          pkgs.haskellPackages.fast-tags

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
          darwin-nix-switch = "darwin-rebuild switch --flake '/Users/romes/control/nix/darwin/?submodules=1'"; # submodules=1 is needed because some modules of the system are in git submodules (such as finances.nix)
          ghc-nix = "nix develop git+https://gitlab.haskell.org/ghc/ghc.nix";
        };
      };

      users.users."romes" = {
        name = "romes";
        home = "/Users/romes";
      };

      # Connect over SSH
      # note: Requires manually setting General > Sharing > Remote Login ON to activate remote login
      users.users."romes".openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ"
      ];
      # Write additional options for sshd_config
      environment.etc."ssh/sshd_config.d/100-romes-nopassword".text = ''
        KbdInteractiveAuthentication no
        PasswordAuthentication no
      '';

      security.pam.enableSudoTouchIdAuth = true; # enable touch id for sudo

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

    };
in
{
  # Build darwin flake using:
  # $ darwin-rebuild build --flake .
  # (it suffices to use `.` because it will read the hostname, e.g., for
  # hostname=romes-mbp it will read associated configuration)
  darwinConfigurations = {
    "romes-mbp" = nix-darwin.lib.darwinSystem {
      modules = [
        common
        ./linux-builder.nix
      ];
    };

    # Nix-darwin configuration for Mac Mini M4 2024
    "romes-macmini" = nix-darwin.lib.darwinSystem {
      modules = [
        common
        ./macmini.nix

        # ./linux-builder.nix

        # Home Manager
        home-manager.darwinModules.home-manager {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.romes = import ../home/romes.nix;
          home-manager.sharedModules = [ nixvim.homeManagerModules.nixvim ];
        }
      ];
    };
  };
};
}
