{ inputs, ... }:
{
  imports = [
    inputs.nix-darwin.flakeModules.default
    inputs.home-manager.flakeModules.home-manager
    # nix-topology ? https://oddlama.github.io/nix-topology/
    # nixos-healthchecks ? https://github.com/mrVanDalo/nixos-healthchecks
    # mission-control ? https://github.com/Platonic-Systems/mission-control#readme
  ];

  config = {
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
