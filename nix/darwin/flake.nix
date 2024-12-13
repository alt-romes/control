{
  description = "Romes MBP Nix-Darwin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs }:
  let
    configuration = { pkgs, ... }: {
      # List packages installed in system profile. To search by name, run:
      # $ nix-env -qaP | grep wget
      environment.systemPackages =
        [ pkgs.vim
        ];

      nix = {
        settings = {

          # Necessary for using flakes on this system.
          experimental-features = [ "nix-command" "flakes" ];

          trusted-users = [ "root" "romes" "@admin" ];

          system-features = [ "nixos-test" "apple-virt" ];
        };

        # linux-builder: background VM running linux to build linux things
        # (e.g. to later remote-deploy them).
        # Sets up `org.nixos.linux-builder` `launchd` service.
        # Inspect with `sudo launchctl list org.nixos.linux-builder`
        linux-builder = {
          # Leave this off by default, and only enable it to build things
          # specifically in linux (e.g. when configuring mogbit server),
          # or doing a cool demo.
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

      # Enable alternative shell support in nix-darwin.
      # programs.fish.enable = true;

      # Set Git commit hash for darwin-version.
      system.configurationRevision = self.rev or self.dirtyRev or null;

      # Used for backwards compatibility, please read the changelog before changing.
      # $ darwin-rebuild changelog
      system.stateVersion = 5;

      # The platform the configuration will be used on.
      nixpkgs.hostPlatform = "aarch64-darwin";
    };
  in
  {
    # Build darwin flake using:
    # $ darwin-rebuild build --flake .
    darwinConfigurations."romes-mbp" = nix-darwin.lib.darwinSystem {
      modules = [ configuration ];
    };
  };
}
