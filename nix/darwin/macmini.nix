# Mac Mini M4
{ lib, pkgs, config, ... }:
{

  imports = [ ./modules/duckdns.nix ];

  finances.daemons = {
    fetchers.enable = true;
    gen-invoice.enable = true;
  };

  # Background linux VM runner process is enabled per-machine as needed
  process.linux-builder.enable = false;

  homebrew = {
    brews = [ ];
    casks = [
        # Creative
        "blender"
        "autodesk-fusion"
        "bambu-studio"
        "affinity-designer"

        # Recreative
        "8bitdo-ultimate-software"
        "steam"
        "minecraft"
        "ultrastardeluxe"

        # Utilities
        "anki"
        "ghostty"
        "vlc"
        "firefox"
        "qbittorrent"
        "skim"
        "mattermost"
        "discord"
        "visual-studio-code" # debugger
    ];
  };

  nixpkgs.config.allowUnfree = true;

  environment = {
    systemPackages = [
      pkgs.tart
    ];
  };

  # --- Network ----------------------------------------------------------------

  age.secrets.duckdns.file = ../../secrets/duckdns.age;
  age.secrets.wireguard-macmini.file = ../../secrets/wireguard-macmini.age;

  # Dynamic DNS
  services.duckdns = {
    enable = true;
    domains = [ "alt-romes" ];
    passwordFile = config.age.secrets.duckdns.path;
    interval = 1800; # every 30min
  };

  # Wireguard
  networking.wg-quick.interfaces = {
    wg0 = {
      address = [ "10.10.10.1/24" "fc10:10:10::1/64" ];
      listenPort = 55902;
      privateKeyFile = config.age.secrets.wireguard-macmini.path; # for hroqsfMWbBsCYhZTiPLNeE/3AK+AdBV3Zn16EJspPX8=
      peers = [
        # wireguard-mbp
        {
          publicKey = "kmpmnUIFpfS4mdOzi7RlGShhSqOcelwIDG+/8mJUAzM=";
          allowedIPs = [ "10.10.10.2/32" "fc10:10:10::2/128" ];
        }
      ];
    };
  };
}
