# Mac Mini M4
{ pkgs, config, ... }:
{

  finances.daemons.enable = true;

  # Background linux VM runner process is enabled per-machine as needed
  process.linux-builder.enable = false;

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
        "minecraft"
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
        "visual-studio-code" # debugger
    ];
  };

  nixpkgs.config.allowUnfree = true;

  environment = {
    systemPackages = [
      pkgs.tart
    ];
  };
}
