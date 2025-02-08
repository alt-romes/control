# Mac Mini M4
{ pkgs, config, ... }:
{

  finances.daemons.enable = false;

  homebrew = {
    brews = [ ];
    casks = [ ];
  };
}
