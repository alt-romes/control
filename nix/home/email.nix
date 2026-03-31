{ pkgs, ... }:
{
  programs.neomutt.enable = true; # Email client

  programs.mbsync.enable = true;  # Email downloader
  programs.msmtp.enable = true;   # Email sender
  programs.notmuch.enable = true; # Email indexer (for searching)

  accounts.email.accounts = {
    mogbit = {
      address = "rodrigo@mogbit.com";
      imap.host = "mail.mogbit.com";
      mbsync = {
        enable = true;
        create = "maildir";
      };
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

