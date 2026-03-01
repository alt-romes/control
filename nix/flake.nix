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

    # nix-rosetta-builder
    nix-rosetta-builder.url = "github:cpick/nix-rosetta-builder";
    nix-rosetta-builder.inputs.nixpkgs.follows = "nixpkgs";

    # Agenix
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # Kimai client
    # Can't use directly because it relies on 1Password agent which it seemingly can't access?
    # kimai-client.url = "git+ssh://git@gitlab.well-typed.com/well-typed/kimai-client.git";
    kimai-client.inputs.nixpkgs.follows = "nixpkgs";
    kimai-client.url = "git+file:///Users/romes/Developer/kimai-client";

    # Charmbracelet NUR
    nur-charmbracelet.url = "github:charmbracelet/nur";
    nur-charmbracelet.inputs.nixpkgs.follows = "nixpkgs";

    # Micasa
    micasa.url = "github:cpcloud/micasa";
    micasa.inputs.nixpkgs.follows = "nixpkgs";

    microvm = {
      url = "github:microvm-nix/microvm.nix/2015b82bbe8bd8ac390e06219077174ba521d16b";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Vscode extensions
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";

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
      "romes-mercury" = commonMDarwinSystem ./darwin/mercury-mbp.nix;

      # Nix-darwin configuration for Mac Mini M4 2025
      "romes-macmini" = commonMDarwinSystem ./darwin/macmini.nix;

    };

    nixosConfigurations = {
      # nixos-rebuild --flake .#red --target-host romes@remote-host # and if not using linux-builder: --build-host romes@remote-host
      "red" = nixpkgs.lib.nixosSystem {
        modules = [ ./linux/red/configuration.nix ];
      };

      # Linux machine named 福助
      # microvm.nix using vfkit (with Rosetta support)
      # Run VM using `nix run .#fukusuke` `run-linux-vm`
      # Login with `ssh -A 127.0.0.1 -p 2222`
      #   (port 2222 is mapped to VM's 22, -A forwards the SSH agent)
      "fukusuke" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          inputs.microvm.nixosModules.microvm
          inputs.home-manager.nixosModules.home-manager
          ./linux/fukusuke/configuration.nix
          {
            microvm.vmHostPackages = nixpkgs.legacyPackages.aarch64-darwin;
            home-manager.extraSpecialArgs = { inherit inputs; system = "aarch64-linux"; };
          }
        ];
      };
    };

    packages.aarch64-darwin = {
      fukusuke-vm = self.nixosConfigurations.fukusuke.config.microvm.declaredRunner;
    };
  };
}
