# MBP M2
{ self, inputs, ... }:
{
  flake.darwinConfigurations.romes-mbp = inputs.nix-darwin.lib.darwinSystem {
    modules = [
      self.darwinModules.romes-mbp
    ];
  };

  flake.darwinModules.romes-mbp = { config, ... }: {

    imports = [
      self.darwinModules.base
    ];

    nix.settings.trusted-public-keys = [ "cult-m4:ptTV1P5s2mpYCfFQMUb+6S8LbtrYK5HfCYas3YrUbho=" ];

    finances = {
      enable = true;
      # Leave daemons for the macmini
      daemons = {
        fetchers.enable = false;
        gen-invoice.enable = false;

        # we don't want to generate invoices nor fetch prices in mbp, but we do
        # want the fava server displaying the ledger file!
        fava-server.enable = true;
      };
    };

    # --- Users ------------------------------------------------------------------

    # UID is necessary. I listed mine out.
    # The rest is in `base.nix` and in the home-manager `romes` config.
    users.users."romes".uid = 501;

    # --- Remote Builders --------------------------------------------------------

    # Background linux VM runner process is enabled per-machine as needed
    process.linux-builder.enable = false;

    # --- Packages ---------------------------------------------------------------

    homebrew = {
      brews = [
      ];
      casks = [
          "steam"
      ];
    };

    # --- Secrets ----------------------------------------------------------------

    age.secrets.wireguard-mbp.file = ../modules/_agenix/wireguard-mbp.age;

    # --- Networking -------------------------------------------------------------

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
        hostname = "10.0.0.1";
        extraOptions = { SetEnv = "TERM=xterm-256color"; };
        forwardAgent = true; # Forward Agent authentication to mbp (basically allowing auth with local 1Pass)
      };
    };

  };
}
