# Mac Mini M4
{ pkgs, config, ... }:
let
  macminiWireguardIp = "10.0.0.1";
in
{

  nix.settings.trusted-public-keys = [ "cult-m4:ptTV1P5s2mpYCfFQMUb+6S8LbtrYK5HfCYas3YrUbho=" ];

  imports = [ (import ./modules/macmini-builder.nix macminiWireguardIp) ];

  # Not here!
  finances.enable = false;

  # --- Remote Builders --------------------------------------------------------

  # Enable distributed builds with the macmini as a builder
  process.macmini-builder.enable = false;

  # Background linux VM runner process is enabled per-machine as needed
  process.linux-builder.enable = false;

  # --- Packages ---------------------------------------------------------------

  homebrew = {
    brews = [
        "qwen-code"
        "gemini-cli"
        "brandonchinn178/tap/hooky"
    ];
    casks = [
        "blender"
        "steam"
        "claude"
        "zed"
        "lm-studio" # llama-server crashes on some models...
    ];
  };

  # --- Networking -------------------------------------------------------------

  age.secrets.wireguard-mercury-mbp.file = ../../secrets/wireguard-mercury-mbp.age;

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
      address = [ "10.0.0.4/32" ];
      privateKeyFile = config.age.secrets.wireguard-mercury-mbp.path; # for ?
      peers = [
        # wireguard-macmini
        {
          publicKey = "hroqsfMWbBsCYhZTiPLNeE/3AK+AdBV3Zn16EJspPX8=";
          allowedIPs = [ "10.0.0.1/24" ]; # allow server to be anywhere
          endpoint = "alt-romes.duckdns.org:55902"; # the dynamic dns we set up with duckdns
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

  # Add an SSH alias
  home-manager.users.romes.programs.ssh.matchBlocks = {
    "macmini" = {
      hostname = macminiWireguardIp;
      extraOptions = { SetEnv = "TERM=xterm-256color"; };
      forwardAgent = true; # Forward Agent authentication to mbp (basically allowing auth with local 1Pass)
    };
  };

  # UID is necessary. I listed mine out.
  users.users."romes".uid = 501;
}
