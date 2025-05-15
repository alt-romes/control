# Mac Mini M4
{ pkgs, config, ... }:
{

  # Background linux VM runner process is enabled per-machine as needed
  process.linux-builder.enable = false;

  # Leave daemons for the macmini
  finances.daemons = {
    fetchers.enable = false;
    gen-invoice.enable = false;
  };

  nixpkgs.config.allowUnfree = true;

  homebrew = {
    brews = [];
    casks = [
        "bambu-studio"
        "affinity-designer"
        "steam"

        "claude"
    ];
  };

  environment = {
    systemPackages = [
      pkgs.tart
    ];
  };

  # --- Networking -------------------------------------------------------------
  age.secrets.wireguard-mbp.file = ../../secrets/wireguard-mbp.age;

  # Wireguard client
  # ---
  # It seems like this doesn't get applied properly while wg is up? possibly
  # because WG is running or the interface is already set up. Use
  # @sudo wg-quick down wg0@ to bring it down before applying the nix config.
  #
  # If nothing works, comment out @wg0@, rebuild, uncomment, rebuild.
  networking.wg-quick.interfaces = {
    wg0 = {
      autostart = true;
      address = [ "10.0.0.2/32" ];
      privateKeyFile = config.age.secrets.wireguard-mbp.path; # for kmpmnUIFpfS4mdOzi7RlGShhSqOcelwIDG+/8mJUAzM=
      peers = [
        # wireguard-macmini
        {
          publicKey = "hroqsfMWbBsCYhZTiPLNeE/3AK+AdBV3Zn16EJspPX8=";
          allowedIPs = [ "10.0.0.1/24" ]; # allow server to be anywhere
          endpoint = "alt-romes.duckdns.org:55902"; # the dynamic dns we set up with duckdns
        }
      ];
    };
  };

  # Add an SSH alias
  home-manager.users.romes.programs.ssh.matchBlocks = {
    "macmini" = {
      hostname = "10.0.0.1";
      extraOptions = { SetEnv = "TERM=xterm-256color"; };
    };
  };
}
