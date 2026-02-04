{ config, lib, pkgs, system, modulesPath, inputs, ... }:

{

  imports = [
    (modulesPath + "/profiles/all-hardware.nix")
  ];

  virtualisation.vmVariant.virtualisation = {
    graphics = false;
    forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
    ];
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.romes = import ../../home/romes.nix;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "dev-vm";
  networking.firewall.enable = false;

  # For remote nixos-rebuild
  nix.settings.trusted-users = [ "romes" ];

  # Set your time zone.
  time.timeZone = "Europe/Portugal";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    useXkbConfig = true; # use xkb.options in tty.
  };

  # hardware.graphics.enable = true;
  # services.seatd.enable = true;
  # services.dbus.enable = true;

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.romes = {
    isNormalUser = true;
    # Login using ssh:
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ romes@world"
    ];
    extraGroups = [ "wheel" "networkmanager" "video" "input" "seat" ]; # Enable ‘sudo’ for the user.
    packages = [ ];
    uid = 1000;
  };

  # $ nix search <package>
  environment.systemPackages = with pkgs; [
    vim
  ];

  services.openssh.enable = true;

  nixpkgs.config.allowUnfree = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.11"; # Did you read the comment?
}

