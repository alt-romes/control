# Mac Mini M4
{ pkgs, config, ... }:
{

  finances.daemons.enable = true;

  homebrew = {

    brews = [ ];

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
