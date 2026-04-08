{ pkgs, ... }:
{
  programs.neomutt.enable = true; # Email client

  programs.mbsync.enable = true; # Email downloader
  programs.msmtp.enable = true;  # Email sender
  programs.mu.enable = true;     # Maildir indexer for mu4e/mu
  programs.notmuch = {           # Email indexer (for searching)
    enable = true;
    hooks = {
      preNew = "mbsync --all";
    };
  };

  accounts.email.accounts = {
    mogbit = {
      address = "rodrigo@mogbit.com";
      aliases = [
        "rodrigo@kanjideck.com"
      ];
      imap.host = "mail.mogbit.com";
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
      passwordCommand = "op item get 'Mogbit Mail' --fields password --reveal";
      smtp = {
        host = "mail.mogbit.com";
      };
      userName = "rodrigo@mogbit.com";
    };
  };
}
