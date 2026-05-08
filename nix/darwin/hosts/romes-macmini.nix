# Build darwin system using:
#
# $ darwin-rebuild build --flake <path>?submodules=1
# (no need to specify attr with `#` because darwin-rebuild uses the hostname as
# default attribute, e.g., for $(hostname)=romes-mbp it will read romes-mbp's
# configuration)
#
# `?submodules=1` is needed because some modules live inside of git submodules

# TODO
# environment.sellAliases
#    ghc-shell = "nix-shell -p haskell.compiler.ghc914 haskellPackages.alex haskellPackages.happy autoconf automake python3 gmp zlib ncurses";
#
#    run-linux-vm = ''
#      IP_FILE=/Users/romes/control/vms/fukusuke/ip
#      if [ -e "$IP_FILE" ]; then
#        PREV_MTIME=$(stat -f %m "$IP_FILE")
#      else
#        PREV_MTIME=0
#      fi
#
#      ${pkgs.tmux}/bin/tmux new -s microvm -d
#      ${pkgs.tmux}/bin/tmux new-window -t microvm: -n vm-console "exec nix run '/Users/romes/control/.#fukusuke-vm'"
#
#      echo "The VM is now running in a tmux session:"
#      echo "  tmux attach -t microvm                "
#
#      echo "Waiting for VM to update IP at $IP_FILE..."
#      while true; do
#        if [ -e "$IP_FILE" ]; then
#          MTIME=$(stat -f %m "$IP_FILE")
#            if [ "$MTIME" -gt "$PREV_MTIME" ]; then
#              break
#            fi
#        fi
#        sleep 0.2
#      done
#
#      echo "Connect to VM with agent forwarding (-A):"
#      echo "  ssh -A $(cat $IP_FILE)"
#    '';

# TODO:
#
#   # ------------------------------------------------------------------------
#   # Agenix secrets

#   # While SSH_AUTH_SOCKET doesn't work, we need to download from 1Password the
#   # key into this path to decrypt the secrets.
#   # See https://github.com/ryantm/agenix/issues/182
#   # once this made the switch fail; but re-running fixed it... it looked like a
#   # race where the identity key wasn't ready yet.
#   age.identityPaths = [ "/Users/romes/.ssh/agenix" ];
#   age.secrets.kimai = {
#     file = ../../secrets/kimai.age;
#     # this secret will be accessed on home-manager activation and when used as a tool
#     # so the user needs permissions
#     owner = "romes";
#   };
#  # Allow localhost reverse proxy resolution for custom domains
#  # The specific virtualHosts are defined where necessary (e.g. in "ledger.localhost" in finances.nix)
#  services.caddy.enable = true;


# Mac Mini M4
{ self, self', inputs, ... }:
{
  flake.darwinConfigurations.romes-macmini = inputs.nix-darwin.lib.darwinSystem {
    modules = [
      self.darwinModules.romes-macmini
    ];
  };

  flake.darwinModules.romes-macmini = { pkgs, config, lib, ... }: {
  
    imports = [
      self.darwinModules.base
      self.darwinModules.duckdns
      self.darwinModules.finances
      self.darwinModules.backups
    ];
 
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
        run-things-url = self'.Shortcut-Run-Things-URL;
      };

      # Note: finances.daemons must be set per-machine depending on
      # whether the periodically scheduled launchd daemons are wanted
      # Currently, this is macmini = ON, mbp = OFF
    };

    # ------------------------------------------------------------------------
    # Networking

    # Allow localhost reverse proxy resolution for custom domains
    # The specific virtualHosts are defined where necessary (e.g. in "ledger.localhost" in finances.nix)
    services.caddy.enable = true;
  
    home-manager.users.romes.programs.kimai.enable = true;
    home-manager.users.romes.programs.custom.doom-emacs = true;
  
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
  };
}
