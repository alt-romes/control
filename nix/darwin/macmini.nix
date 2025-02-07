# Mac Mini M4
{ pkgs, hledgerfile, ... }:
let
    # import default.nix from the repo, apply it to the current nixpkgs, and
    # select the activobank-hs package out.
    activobank-hs-repo = pkgs.fetchFromGitHub {
        owner = "alt-romes";
        repo  = "activobank-hs";
        rev   = "master";
        hash  = "sha256-DUfjSGF1fdo9fYeo9uwY5Zpo3fPtFYt47Djvvb/Vfls=";
    };
    activobank-hs = (import activobank-hs-repo { nixpkgs = pkgs; }).activobank-hs;
in
{

  # user daemons
  launchd = {
    user = {
      agents = {
        activobank-fetch = {
           # Use binary from building derivation
           script = ''
             ${activobank-hs}/bin/hledger-activobank \
                ||  osascript -e "display notification \"Failed to synchronise! See log in /tmp\" with title \"ActivoBank Hledger Daemon\""
           '';
           environment = {
             LC_ALL = "UTF-8";
             LEDGER_FILE = hledgerfile;
           };
           # Runs every day at 21:30
           serviceConfig = {
               StartCalendarInterval = {
                 Hour = 21;
                 Minute = 30;
               };
               StandardOutPath   = "/tmp/org.romes.activobank-hs.out.log";
               StandardErrorPath = "/tmp/org.romes.activobank-hs.err.log";
           };
        };
      };
    };
  };

  environment = {
    systemPackages = [
        activobank-hs # hledger-activobank
    ];
  };

  homebrew = {

    brews = [

    ];

    casks = [
        "blender"
        "autodesk-fusion"
        "bambu-studio"
        "affinity-designer"

        "8bitdo-ultimate-software"
        "steam"

        "anki"
        "vlc"
        "ghostty"
        "firefox"
        "qbittorrent"
        "skim"

        "mattermost"
        "discord"
    ];
  };
}
