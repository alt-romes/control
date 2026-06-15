{
  description = "Core Control System";

  inputs = {
    # Structural deps
    nixpkgs.url      = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # QEMU was broken on head. Pin older version.
    nixpkgs-qemu.url = "github:NixOS/nixpkgs/nixos-25.11";
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
    activobank-hs.url   = "github:alt-romes/activobank-hs";
    activobank-hs.flake = false;
    codex-cli-nix.url   = "github:sadjow/codex-cli-nix";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    nix-doom-emacs-unstraightened.url = "github:marienz/nix-doom-emacs-unstraightened";

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

    # Follow flake-parts
    nixvim.inputs.flake-parts.follows       = "flake-parts";
    kimai-client.inputs.flake-parts.follows = "flake-parts";

    # Follow systems (many deps pull it in independently)
    systems.url = "github:nix-systems/default";
    flake-utils.inputs.systems.follows                        = "systems";
    nixvim.inputs.systems.follows                             = "systems";
    nix-doom-emacs-unstraightened.inputs.systems.follows      = "systems";
    agenix.inputs.systems.follows                             = "systems";

    # Collapse nixpkgs-lib into nixpkgs (flake-parts only needs lib)
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # Collapse agenix's bundled home-manager and nix-darwin into ours
    agenix.inputs.home-manager.follows = "home-manager";
    agenix.inputs.darwin.follows       = "nix-darwin";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; }
    {
      imports = [
        (inputs.import-tree [./nix ./finances/nix])
      ];

      # Flake-wide constants shared with every module as an extra module arg.
      _module.args = {
        # Default GHC across the flake.
        ghcVersion = "ghc914";
      };
    };
}
