# Mac Mini M4
{ pkgs, config, ... }:
{

  # Background linux VM runner process is enabled per-machine as needed
  process.linux-builder.enable = false;

  # Leave journal synchronisation for the macmini
  finances.daemons.enable = false;
  finances.gen-invoice.enable = false;

  homebrew = {
    brews = [ ];
    casks = [ ];
  };

  # --- Networking -------------------------------------------------------------
  age.secrets.wireguard-mbp.file = ../../secrets/wireguard-mbp.age;

  # Wireguard client
  networking.wg-quick.interfaces = {
    wg0 = {
      address = [ "10.10.10.2/32" "fc10:10:10::2/128" ];
      privateKeyFile = config.age.secrets.wireguard-mbp.path; # for kmpmnUIFpfS4mdOzi7RlGShhSqOcelwIDG+/8mJUAzM=
      peers = [
        # wireguard-macmini
        {
          publicKey = "hroqsfMWbBsCYhZTiPLNeE/3AK+AdBV3Zn16EJspPX8=";
          allowedIPs = [ "0.0.0.0/0" "::/0" ]; # allow server to be anywhere
          endpoint = "alt-romes.duckdns.org:55902"; # the dynamic dns we set up with duckdns
        }
      ];
    };
  };

}
