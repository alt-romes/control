# Mac Mini M4
{ pkgs, ... }: {
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

        "inform" # interactive fiction tool, ref. in that talk at TFP

        "mattermost"
        "discord"
    ];
  };
}
