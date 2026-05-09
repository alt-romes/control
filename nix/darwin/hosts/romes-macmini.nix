# Build darwin system using:
#
# $ darwin-rebuild build --flake <path>?submodules=1
# (no need to specify attr with `#` because darwin-rebuild uses the hostname as
# default attribute, e.g., for $(hostname)=romes-mbp it will read romes-mbp's
# configuration)
#
# `?submodules=1` is needed because some modules live inside of git submodules

# Mac Mini M4
{ self, inputs, ... }:
{
  flake.darwinConfigurations.romes-macmini = inputs.nix-darwin.lib.darwinSystem {
    modules = [
      self.darwinModules.romes-macmini
    ];
  };

  flake.darwinModules.romes-macmini = { pkgs, config, ... }: {
  
    imports = [
      self.darwinModules.base
      self.darwinModules.duckdns
      self.darwinModules.finances
      self.darwinModules.backups
    ];

    # --------------------------------------------------------------------------------
    # My modules
 
    finances = {
      enable = true;
      daemons = {
        fetchers.enable = true;
        gen-invoice.enable = true;
        fava-server.enable = true;
      };

      all.ledger = "/Users/romes/control/finances/all.journal";
      personal.ledger = "/Users/romes/control/finances/2025.journal";
      mogbit.ledger = "/Users/romes/control/finances/mogbit/2025.journal";
      prices.ledger = "/Users/romes/control/finances/prices.journal";

      # Packages needed to build some of the finance utilities
      packages = {
        kimai = config.home-manager.users.romes.programs.kimai.package;
        run-things-url = self.packages.${pkgs.stdenv.hostPlatform.system}.Shortcut-Run-Things-URL;
      };

      # Note: finances.daemons must be set per-machine depending on
      # whether the periodically scheduled launchd daemons are wanted
      # Currently, this is macmini = ON, mbp = OFF
    };

    # Allow localhost reverse proxy resolution for custom domains
    # The specific virtualHosts are defined where necessary (e.g. in "ledger.localhost" in finances.nix)
    services.caddy.enable = true;
  
    home-manager.users.romes.programs.custom.doom-emacs = true;

    # --- Users ------------------------------------------------------------------

    # UID is necessary. I listed mine out.
    # The rest is in `base.nix` and in the home-manager `romes` config.
    users.users."romes".uid = 501;
  
    # --- Builders ---------------------------------------------------------------
  
    # Background linux VM runner process is enabled per-machine as needed
    process.linux-builder.enable = true;
  
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
          "curseforge"
          # "ultrastardeluxe"
  
          # Utilities
          "qbittorrent"
          "vorta" # borgbackup gui
  
          # Xperiments
          "antigravity"
          "codex-app"
      ];
    };

    environment.systemPackages = [
       pkgs.iina   # video player
    ];
  
    # --- Network ----------------------------------------------------------------
  
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
  };
}
