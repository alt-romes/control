# Darwin linux builder
{ pkgs, lib, config, ... }: {

  options.process.linux-builder.enable
    = lib.mkEnableOption "Enable a linux-builder background-running VM to send target=linux jobs to.";

  config = lib.mkIf config.process.linux-builder.enable {

    nix = {

      # linux-builder: background VM running linux to build linux things
      # (e.g. to later remote-deploy them).
      # Sets up `org.nixos.linux-builder` `launchd` service.
      # Inspect with `sudo launchctl list org.nixos.linux-builder`
      linux-builder = {
        # Leave this off by default, and only enable it to build things
        # specifically in linux (e.g. when configuring mogbit server),
        # or doing a cool demo.
        #
        # Remember to shut this down when not needed! Also, using a nixos
        # docker and running linux-specific tasks in it seems much faster than
        # the background runner for now, so that's one option
        #
        # Note for future: enabling and disabling (and applying) is sufficient
        # to stop and start the service. Don't worry, it isn't left running in
        # the background when this is disabled.
        enable = false;

        # cleans up machines on restart
        ephemeral = true;
        maxJobs = 4; # number of jobs that may be delegated concurrently to this builder.
        config = {
          virtualisation = {
            darwin-builder = {
              diskSize = 40*1024; # 40GB disk
              memorySize = 8*1024; # 8GB RAM
            };
            cores = 4;
          };
        };
        # supportedFeatures = [ "kvm" "benchmark" "big-parallel" "nixos-test" ];
      };

      # This line is a prerequisite?
      # settings.trusted-users = [ "@admin" ];

      # Enable building pkgs on x86_64-darwin as well
      extraOptions = ''
        extra-platforms = x86_64-darwin aarch64-darwin
      '';

    };

  };

}
