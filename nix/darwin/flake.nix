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
  sys = {pkgs, ...}: {
    # Used for backwards compatibility, please read the changelog before changing.
    # $ darwin-rebuild changelog
    system.stateVersion = 5;

    system.configurationRevision = self.rev or self.dirtyRev or null;
    nixpkgs.hostPlatform = "aarch64-darwin";
  };
in
{
  # Build darwin flake using:
  #
  # $ darwin-rebuild build --flake <path>?submodules=1
  # (it suffices to use `.` because it will read the hostname, e.g., for
  # hostname=romes-mbp it will read associated configuration)
  #
  # `?submodules=1` is needed because some modules live inside of git submodules
  darwinConfigurations = {

    "romes-mbp" = nix-darwin.lib.darwinSystem {

      modules = [
        sys
        ./common.nix
        ./mbp.nix
      ];

    };

    # Nix-darwin configuration for Mac Mini M4 2025
    "romes-macmini" = nix-darwin.lib.darwinSystem {

      modules = [
        sys
        ./common.nix
        ./macmini.nix
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
