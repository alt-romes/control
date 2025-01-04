{
  description = "Romes Nix-Darwin, for MBP M2 and Mac Mini M4";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

outputs = inputs@{ self, nix-darwin, nixpkgs }:
{
  # Build darwin flake using:
  # $ darwin-rebuild build --flake .
  # (it suffices to use `.` because it will read the hostname, e.g., for romes-mbp it will read associated configuration)
  darwinConfigurations = {
    "romes-mbp" = nix-darwin.lib.darwinSystem {
      modules = [
        ./shared.nix
      ];
    };

    # Nix-darwin configuration for Mac Mini M4 2024
    "romes-macmini" = nix-darwin.lib.darwinSystem {
      modules = [
        ./shared.nix
      ];
    };
  };
};
}
