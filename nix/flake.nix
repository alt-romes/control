{
  description = "Core Control System";

  inputs = {
    # Structural deps
    nixpkgs.url      = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url  = "github:hercules-ci/flake-parts";
    import-tree.url  = "github:vic/import-tree";
    nix-darwin.url   = "github:LnL7/nix-darwin";
    home-manager.url = "github:nix-community/home-manager";
    nixvim.url       = "github:nix-community/nixvim";

    # More deps
    microvm.url         = "github:microvm-nix/microvm.nix";
    agenix.url          = "github:ryantm/agenix";
    kimai-client.url    = "git+ssh://git@gitlab.well-typed.com/well-typed/kimai-client.git";
      # ^ When this doesn't work directly and asks for password,
      # `nix flake update kimai-client` manually fixes it
    hadrian-util.url    = "git+https://gitlab.haskell.org/bgamari/hadrian-util";
    mercury-cli.url     = "github:MercuryTechnologies/mercury-cli";
    codex-cli-nix.url   = "github:sadjow/codex-cli-nix";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    nix-doom-emacs-unstraightened.url = "github:marienz/nix-doom-emacs-unstraightened";
    # nix-rosetta-builder.url = "github:cpick/nix-rosetta-builder";

    # Follow nixpkgs
    nix-darwin.inputs.nixpkgs.follows      = "nixpkgs";
    home-manager.inputs.nixpkgs.follows    = "nixpkgs";
    nixvim.inputs.nixpkgs.follows          = "nixpkgs";
    microvm.inputs.nixpkgs.follows         = "nixpkgs";
    agenix.inputs.nixpkgs.follows          = "nixpkgs";
    kimai-client.inputs.nixpkgs.follows    = "nixpkgs";
    hadrian-util.inputs.nixpkgs.follows    = "nixpkgs";
    mercury-cli.inputs.nixpkgs.follows     = "nixpkgs";
    codex-cli-nix.inputs.nixpkgs.follows   = "nixpkgs";
    claude-code-nix.inputs.nixpkgs.follows = "nixpkgs";
    nix-doom-emacs-unstraightened.inputs.nixpkgs.follows = "nixpkgs";

    # Follow flake-utils (we don't use it, flake-parts is much better, but many deps do)
    flake-utils.url = "github:numtide/flake-utils";
    codex-cli-nix.inputs.flake-utils.follows   = "flake-utils";
    mercury-cli.inputs.flake-utils.follows     = "flake-utils";
    claude-code-nix.inputs.flake-utils.follows = "flake-utils";
    hadrian-util.inputs.flake-utils.follows    = "flake-utils";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; }
    (inputs.import-tree ./modules);

  # outputs = inputs@{ self, nix-darwin, nixpkgs, ... }:
  #   let
  #
  #   common = { nixpkgs.overlays = [ inputs.claude-code-nix.overlays.default ]; };
  #
  #   commonMDarwinSystem = customSystemModule: nix-darwin.lib.darwinSystem {
  #
  #     specialArgs = {
  #       inherit inputs;
  #       system = "aarch64-darwin";
  #       configurationRevision = self.rev or self.dirtyRev or null;
  #     };
  #
  #     modules = [
  #       common
  #       ./darwin/common.nix
  #         customSystemModule
  #     ];
  #
  #   };
  #
  # in
  # {
  #   # Build darwin flake using:
  #   #
  #   # $ darwin-rebuild build --flake <path>?submodules=1
  #   # (it suffices to use `.` because it will read the hostname, e.g., for
  #   # hostname=romes-mbp it will read associated configuration)
  #   #
  #   # `?submodules=1` is needed because some modules live inside of git submodules
  #   darwinConfigurations = {
  #
  #     "romes-mbp" = commonMDarwinSystem ./darwin/mbp.nix;
  #     "romes-mercury" = commonMDarwinSystem ./darwin/mercury-mbp.nix;
  #
  #     # Nix-darwin configuration for Mac Mini M4 2025
  #     "romes-macmini" = commonMDarwinSystem ./darwin/macmini.nix;
  #
  #   };
  #
  #   nixosConfigurations = {
  #     # nixos-rebuild --flake .#red --target-host romes@remote-host # and if not using linux-builder: --build-host romes@remote-host
  #     "red" = nixpkgs.lib.nixosSystem {
  #       modules = [ ./linux/red/configuration.nix ];
  #     };
  #
  #     # Linux machine named 福助
  #     # microvm.nix using vfkit (with Rosetta support)
  #     # Run VM using `nix run .#fukusuke-vm` `run-linux-vm`
  #     # Login with `ssh -A 127.0.0.1 -p 2222`
  #     #   (port 2222 is mapped to VM's 22, -A forwards the SSH agent)
  #     "fukusuke" = nixpkgs.lib.nixosSystem {
  #       system = "aarch64-linux";
  #       specialArgs = { inherit inputs; };
  #       modules = [
  #         common
  #         inputs.microvm.nixosModules.microvm
  #         inputs.home-manager.nixosModules.home-manager
  #         ./linux/fukusuke/configuration.nix
  #         {
  #           microvm.vmHostPackages = nixpkgs.legacyPackages.aarch64-darwin;
  #           home-manager.extraSpecialArgs = {
  #             inherit inputs;
  #             system = "aarch64-linux";
  #             minimal = true;
  #           };
  #         }
  #       ];
  #     };
  #   };
  #
  #   packages.aarch64-darwin = {
  #     fukusuke-vm = self.nixosConfigurations.fukusuke.config.microvm.declaredRunner;
  #   };
  # };
}
