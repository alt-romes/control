# Mac Mini M4
{ pkgs, config, ... }:
{

  finances.daemons.enable = true;

  homebrew = {
    brews = [ ];
    casks = [
        # Creative
        "blender"
        "autodesk-fusion"
        "bambu-studio"
        "affinity-designer"

        # Recreative
        "8bitdo-ultimate-software"
        "steam"
        "ultrastardeluxe"

        # Utilities
        "anki"
        "ghostty"
        "vlc"
        "firefox"
        "qbittorrent"
        "skim"
        "mattermost"
        "discord"
    ];
  };
}
