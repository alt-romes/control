# Mac Mini M4
{ pkgs, config, ... }:
{

  # Enable the linux builder as needed.
  # Off for now.
  process.linux-builder.enable = false;

  # Leave journal synchronisation for the macmini
  finances.daemons.enable = false;

  homebrew = {
    brews = [ ];
    casks = [ ];
  };
}
