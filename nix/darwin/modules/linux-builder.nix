# Darwin linux builder
# On the first time that the linux-builder is being run on any given machine:
# See https://github.com/NixOS/nixpkgs/blob/master/doc/packages/darwin-builder.section.md for bootstrapping
# i.e. on the first run you may need to run this first:
#  nix run nixpkgs#darwin.linux-builder
{ pkgs, lib, config, inputs, ... }: {

  options.process.linux-builder.enable
    = lib.mkEnableOption "Enable a linux-builder background-running VM to send target=linux jobs to.";

  imports = [
      # An existing Linux builder is needed to initially bootstrap `nix-rosetta-builder`.
      # If one isn't already available: comment out the `nix-rosetta-builder` module below,
      # uncomment this `linux-builder` module, and run `darwin-rebuild switch`:
      # { nix.linux-builder.enable = true; }
      # Then: uncomment `nix-rosetta-builder`, remove `linux-builder`, and `darwin-rebuild switch`
      # a second time. Subsequently, `nix-rosetta-builder` can rebuild itself.
      inputs.nix-rosetta-builder.darwinModules.default
  ];

  config = lib.mkIf config.process.linux-builder.enable {

    # See more available options in module.nix's `options.nix-rosetta-builder`

    # Shutdown automatically and only run it on demand
    # nix-rosetta-builder.onDemand = true;
  };

}
