{ self, ... }:
{
  flake.homeModules.email = { osConfig, config, lib, pkgs, ... }:
  let
    watched = config.programs.custom.mail-events;
  in {
    options.programs.custom.mail-events = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Fetch mail on push and publish a control-events event per new mail.";
    };

    config = {
      services.imapnotify.enable = watched;
      services.imapnotify.package = pkgs.goimapnotify.overrideAttrs (old: {
        # Events with no command (e.g. flag changes) were taking the 1s
        # debounce timer which caused new mail to be skipped. AI investigated so ...
        patches = (old.patches or [ ]) ++ [ ./goimapnotify-skip-no-command.patch ];
      });
      launchd.agents.imapnotify-mogbit.config = lib.mkIf watched {
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/imapnotify-mogbit.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/imapnotify-mogbit.log";
      };

      programs.neomutt.enable = true; # Email client

      programs.mbsync.enable = true; # Email downloader
      programs.msmtp.enable = true;  # Email sender
      programs.mu.enable = true;     # Maildir indexer for mu4e/mu
      programs.notmuch = {           # Email indexer (for searching)
        enable = true;
        new.tags = [ "unread" "inbox" ] ++ lib.optional watched "new";
        hooks = {
          preNew = "${lib.getExe config.programs.mbsync.package} --all";
          postNew = lib.mkIf watched
            (lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.mail-events);
        };
      };

      accounts.email.accounts = {
        mogbit = {
          address = "rodrigo@mogbit.com";
          aliases = [
            "rodrigo@kanjideck.com"
          ];
          imap.host = "mail.mogbit.com";
          imapnotify = {
            enable = true;
            boxes = [ "INBOX" ];
            onNotify = "${lib.getExe config.programs.notmuch.package} new";
          };
          mbsync = {
            enable = true;
            create = "maildir";
          };
          mu.enable = true;
          neomutt.enable = true;
          msmtp.enable = true;
          notmuch.enable = true;
          primary = true;
          realName = "Rodrigo Mesquita";
          passwordCommand = "cat ${osConfig.age.secrets.mogbit-mail.path}";
          smtp = {
            host = "mail.mogbit.com";
          };
          userName = "rodrigo@mogbit.com";
        };
      };
    };
  };
}
