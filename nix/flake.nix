{
  description = "Romes Nix-Darwin, for MBP M2 and Mac Mini M4";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # Home manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Nixvim
    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    # Agenix
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # Kimai client
    kimai-client.url = "git+ssh://git@gitlab.well-typed.com/well-typed/kimai-client.git?ref=bolt12/patch"; # remove the ref once merged
    # kimai-client.url = "git+file:///Users/romes/Developer/kimai-client";
  };

outputs = inputs@{ self, nix-darwin, nixpkgs, ... }:
let

  commonMDarwinSystem = customSystemModule: nix-darwin.lib.darwinSystem {

    specialArgs = {
      inherit inputs;
      system = "aarch64-darwin";
      configurationRevision = self.rev or self.dirtyRev or null;
    };

    modules = [
      ./darwin/common.nix
      customSystemModule
    ];

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

    "romes-mbp" = commonMDarwinSystem ./darwin/mbp.nix;

    # Nix-darwin configuration for Mac Mini M4 2025
    "romes-macmini" = commonMDarwinSystem ./darwin/macmini.nix;

  };

};
}
