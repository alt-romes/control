# Nix-darwin configuration for Mercury's MBP M4
{ self, inputs, ... }:
{
  flake.darwinConfigurations.romes-mercury = inputs.nix-darwin.lib.darwinSystem {
    modules = [
      self.darwinModules.romes-mercury
    ];
  };

  flake.darwinModules.romes-mercury = { config, pkgs, ... }: {

    imports = [
      self.darwinModules.base
    ];

    nix.settings.trusted-public-keys = [ "cult-m4:ptTV1P5s2mpYCfFQMUb+6S8LbtrYK5HfCYas3YrUbho=" ];

    home-manager.users.romes.programs.custom.doom-emacs = true;

    # --- Users ------------------------------------------------------------------

    # UID is necessary. I listed mine out.
    # The rest is in `base.nix` and in the home-manager `romes` config.
    users.users."romes".uid = 501;

    # --- Remote Builders --------------------------------------------------------

    # Background linux VM runner process is enabled per-machine as needed
    process.linux-builder.enable = true;

    # --- Packages ---------------------------------------------------------------

    homebrew = {
      brews = [
      ];
      casks = [
          "antigravity"
          "blender"
          "steam"
          "claude"
          "zed"
          "lm-studio" # llama-server crashes on some models...
      ];
    };

    # --- Secrets ----------------------------------------------------------------

    age.secrets.wireguard-mercury.file = ../modules/_agenix/wireguard-mercury.age;

    # --- Networking -------------------------------------------------------------

    # Wireguard client
    # ---
    # It seems like this doesn't get applied properly while wg is up? possibly
    # because WG is running or the interface is already set up. Use
    # @sudo wg-quick down wg0@ to bring it down before applying the nix config.
    #
    # If nothing works, comment out @wg0@, rebuild, uncomment, rebuild.
    networking.wg-quick.interfaces = {
      wg1 = {
        autostart = true;
        address = [ "10.0.0.4/32" ];
        privateKeyFile = config.age.secrets.wireguard-mercury.path;
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
    home-manager.users.romes.programs.ssh.settings = {
      "macmini" = {
        HostName = "10.0.0.1";
        SetEnv = { TERM = "xterm-256color"; };
        ForwardAgent = true; # Forward Agent authentication to mbp (basically allowing auth with local 1Pass)
      };
    };
  };
}
