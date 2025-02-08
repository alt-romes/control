# Mac Mini M4
{ pkgs, config, ... }:
{

  imports = [
    ../../finances/finances.nix
  ];

  finances = {
    enable = true;
    daemons.enable = true;
    personal.ledger = "/Users/romes/control/finances/2024.journal";
    mogbit.ledger = "/Users/romes/control/finances/mogbit/2024.journal";
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
