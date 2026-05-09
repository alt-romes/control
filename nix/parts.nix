{ inputs, lib, ... }:
{
  imports = [
    inputs.nix-darwin.flakeModules.default
    inputs.home-manager.flakeModules.home-manager
    # nix-topology ? https://oddlama.github.io/nix-topology/
    # nixos-healthchecks ? https://github.com/mrVanDalo/nixos-healthchecks
    # mission-control ? https://github.com/Platonic-Systems/mission-control#readme
  ];

  options.flake.darwinModules = lib.mkOption {
    # nix-darwin only declares darwinConfigurations. they are essentially the
    # same just different names (well, and you should use `modules = [...]`in
    # configurations and `imports = [...]` in modules. copy the definition here.
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = { };
    description = "Darwin system modules";
  };

  config = {
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
