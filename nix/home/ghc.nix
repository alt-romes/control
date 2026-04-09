# Utilities for working on GHC.
{ pkgs, inputs, ... }:
let
  hadrianUtil = inputs.hadrian-util.packages.${pkgs.system}.default;
in
{
  home.packages = [
    hadrianUtil
  ];

  programs.zsh.shellAliases.hu = "hadrian-util";
}
