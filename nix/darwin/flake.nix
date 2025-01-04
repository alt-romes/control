{
  description = "Romes Nix-Darwin, for MBP M2 and Mac Mini M4";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

outputs = inputs@{ self, nix-darwin, nixpkgs }:
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
	casks = []; # casks, per-machine configuration (see relevant files)

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
      };

      # Enable alternative shell support in nix-darwin.
      # programs.fish.enable = true;

      environment = {
        variables = {
          HISTCONTROL = "ignoredups";

          EDITOR = "vim";

          LEDGER_FILE = "$HOME/control/finances/2024.journal";
        };

        shellAliases = {
          is = "hledger is -X € -M --change Income Expenses -AT -2 -b'this year' --pretty";
          bs = "hledger bs -X € -M --historical Assets Liabilities -3 -b'this year' --pretty";
          cf = "hledger cf -X € -M -AT -3 -b'this year' --pretty";

          mv = "mv -i";
          cp = "cp -i";

          g = "git";
          httpserver = "python -m http.server 25565";
          darwin-nix-switch = "darwin-rebuild switch --flake $HOME/control/nix/darwin/";
        };

        # List packages installed in system profile. To search by name, run:
        # $ nix-env -qaP | grep wget
        systemPackages = [
          pkgs.vim
          pkgs.colmena       # deployment tool
          pkgs.nixos-rebuild # to deploy to remote nixos machines directly
        ];
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
        # ./linux-builder.nix
        ./macmini.nix
      ];
    };
  };
};
}
