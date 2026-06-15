# Darwin linux builder
# On the first time that the linux-builder is being run on any given machine:
# See https://github.com/NixOS/nixpkgs/blob/master/doc/packages/darwin-builder.section.md for bootstrapping
# i.e. on the first run you may need to run this first:
#  nix run nixpkgs#darwin.linux-builder
#
# Another recent write up (2026): https://abhinavsarkar.net/notes/2026-microvm-nix/#cb2-10
{ inputs, ... }:
{
  flake.darwinModules.linux-builder = { pkgs, lib, config, ... }: {

    options.process.linux-builder.enable
      = lib.mkEnableOption "Enable a linux-builder background-running VM to send target=linux jobs to.";

    config = {
      nix.linux-builder = {
        enable = config.process.linux-builder.enable;
        package = pkgs.darwin.linux-builder;
        systems = [ "aarch64-linux" ];
        config = {
          virtualisation.cores = 6;        # Number of CPU cores
          virtualisation.memorySize = lib.mkForce 16384; # RAM in MB (16 GB)
          virtualisation.diskSize = lib.mkForce 51200; # 50GB instead of default 20GB
        };
      };

      # QEMU on head was broken; pin older version
      nixpkgs.overlays = lib.mkIf config.process.linux-builder.enable [
        (final: prev: {
          qemu_kvm = inputs.nixpkgs-qemu.legacyPackages.${prev.stdenv.hostPlatform.system}.qemu_kvm;
        })
      ];
    };
  };
}
