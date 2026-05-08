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
    (inputs.import-tree [./nix ./finances/nix]);
}
