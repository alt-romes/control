# Mac Mini M4
{ pkgs, config, ... }:
{

  # Background linux VM runner process is enabled per-machine as needed
  process.linux-builder.enable = false;

  # Leave journal synchronisation for the macmini
  finances.daemons.enable = false;

  homebrew = {
    brews = [ ];
    casks = [ ];
  };


}
