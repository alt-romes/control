{ config, lib, pkgs, ... }:
{
  # VM configuration using microvm.nix
  microvm = {
    hypervisor = "vfkit";
    vcpu = 8;
    mem = 32768; # I guess these should depend on where the VM is run from but OK
    graphics.enable = false;
    # Enable ability to run x86 binaries in the VM using rosetta
    vfkit.rosetta = {
      enable = false;
      install = false; # install if not available
    };
    shares = [
      # Share (read-only) Nix store
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
      # ghc-dev
      {
        source = "/Users/romes/ghc-dev";
        mountPoint = "/home/romes/ghc-dev";
        tag = "ghc-dev";
        proto = "virtiofs";
      }
      # Developer
      {
        source = "/Users/romes/Developer";
        mountPoint = "/home/romes/Developer";
        tag = "Developer";
        proto = "virtiofs";
      }
    ];
    interfaces = [{
      type = "user";
      id = "usernet";
      mac = "02:00:00:01:01:08";
    }];
    socket = "fukusuke-vm.sock";
    # Only supported with qemu hypervisor
    # forwardPorts = [
    #   { from = "host"; host.port = 2222; guest.port = 22; }
    # ];
    # Add writable nix store to build derivations inside the VM
    writableStoreOverlay = "/nix/.rw-store";
    volumes = [
      # Volume for writable nix store
      {
        image = "/Users/romes/control/vms/nix-store-overlay.img";
        mountPoint = config.microvm.writableStoreOverlay;
        size = 16384; # 16GB
      }
    ];
  };

  nix.settings = {
    trusted-users = [ "romes" ];
    experimental-features = [ "nix-command" "flakes" ];
  };
  nixpkgs.config.allowUnfree = true;

  time.timeZone = "Europe/Portugal";
  
  networking = {
    hostName = "fukusuke";
    # Disable firewall for faster boot and less hassle;
    # we are behind a layer of NAT anyway.
    firewall.enable = false;
  };

  environment = {
    systemPackages = with pkgs; [
      htop
    ];
    variables = {
      HISTCONTROL = "ignoredups";
      EDITOR = "vim";
    };
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  users.users.romes = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ romes@world"
    ];
    extraGroups = [ "wheel" "networkmanager" "video" "input" "seat" ]; # Enable ‘sudo’ for the user.
    packages = [ ];
    uid = 1000;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.romes = {
    imports = [
      ../../home/romes.nix
    ];
  };

  services.openssh.enable = true;

  services.getty.autologinUser = "romes";

  # environment.etc."motd".text = ''
  #   vfkit Test VM - Apple Silicon
  #   Features:
  #     - Graphics (virtio-gpu + GUI, if enabled)
  #     - Rosetta (x86_64 emulation)
  #     - virtiofs /nix/store sharing
  #     - NAT networking
  #   Test commands:
  #     uname -m                    # aarch64
  #     file $(which hello-x86_64)  # x86-64
  #     hello-x86_64                # runs via Rosetta!
  #     ping -c 3 1.1.1.1           # network test
  # '';
  # programs.bash.loginShellInit = "cat /etc/motd";

  # The microvm module already sets up the rosetta filesystem and binfmt
  # We just need to set the state version
  system.stateVersion = "25.11";
}
