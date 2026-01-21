# Mac Mini M4
{ lib, pkgs, config, ... }:
{

  imports = [ ./modules/duckdns.nix ./modules/backups.nix ];

  finances = {
    enable = true;
    daemons = {
      fetchers.enable = true;
      gen-invoice.enable = true;
    };
  };

  # --- Builders ---------------------------------------------------------------

  # Background linux VM runner process is enabled per-machine as needed
  process.linux-builder.enable = true;

  # Create a user on this machine for when this machine is used as a remote
  # builder (e.g. by the MBP)
  users.users."nix-builder" = {
    uid = 4323;
    gid = config.users.groups."nix-builders".gid;
    shell = pkgs.zsh;

    createHome = false;

    # NOTE: For remote access to work, Remote Login must be allowed in the
    # MacOS settings!!
    openssh.authorizedKeys.keys = [
      # public key from secrets/remote-builder-key.age
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7pAwlZfwA4kGL4NhWZy9tSnu0jKoXt77L2Noj5hw7z"
    ];
  };
  users.groups."nix-builders" = { gid = 4322; }; # made up number for groupid
  nix.settings.trusted-users = [ "nix-builder" ];
  users.knownUsers  = [ "nix-builder" ];  # users managed by nix-darwin
  users.knownGroups = [ "nix-builders" ]; # groups managed by nix-darwin

  # --- Packages ---------------------------------------------------------------

  homebrew = {
    brews = [
        "qwen-code"
        "gemini-cli"
    ];
    casks = [
        # Creative
        "blender"
        "autodesk-fusion"
        "bambu-studio"

        # Recreative
        "8bitdo-ultimate-software"
        "steam"
        "minecraft"
        "ultrastardeluxe"

        # Utilities
        "qbittorrent"
        "vorta" # borgbackup gui

        # Xperiments
        "antigravity"
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

  # Wake on LaN
  networking.wakeOnLan.enable = true;

  # Wireguard
  # ---
  # It seems like this doesn't get applied properly while wg is up? possibly
  # because WG is running or the interface is already set up. Use
  # @sudo wg-quick down wg0@ to bring it down before applying the nix config.
  #
  # If nothing works, comment out @wg0@, rebuild, uncomment, rebuild.
  networking.wg-quick.interfaces = {
    wg0 = {
      autostart = true;
      address = [ "10.0.0.1/24" ];
      listenPort = 55902;
      privateKeyFile = config.age.secrets.wireguard-macmini.path; # for hroqsfMWbBsCYhZTiPLNeE/3AK+AdBV3Zn16EJspPX8=
      peers = [
        # wireguard-mbp
        {
          publicKey = "kmpmnUIFpfS4mdOzi7RlGShhSqOcelwIDG+/8mJUAzM=";
          allowedIPs = [ "10.0.0.2/32" ];
        }
        # mogbit.com
        {
          publicKey = "jXdArfJv5HWvPgCWiaCtslExWXKn5PQgSSBnw0Kn0h8=";
          allowedIPs = [ "10.0.0.3/32" ];
          # use mail subdomain bc it is not proxied
          endpoint = "mail.mogbit.com:55820";
        }
      ];
    };
  };

  # UID is necessary. See man id(1) to find the right one for a machine.
  # The one for macmini:
  users.users."romes".uid = 501;
}
