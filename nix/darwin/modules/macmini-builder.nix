macminiWireguardIp: { pkgs, lib, config, ... }:
{
  options.process.macmini-builder.enable
    = lib.mkEnableOption "Enable the macmini machine as an additional builder and toggle distributed builds.";

  config = lib.mkIf config.process.macmini-builder.enable
  {
    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;

    # Builds locally and on the buildMachines
    nix.buildMachines = [
      {
        hostName = macminiWireguardIp;
        sshUser = "nix-builder";
        sshKey = config.age.secrets.remote-builder-key.path;
        system = pkgs.stdenv.hostPlatform.system;
        supportedFeatures = [ "nixos-test" "big-parallel" "kvm" ];
      }
    ];

    age.secrets.remote-builder-key.file = ../../../secrets/remote-builder-key.age;
  };
}
