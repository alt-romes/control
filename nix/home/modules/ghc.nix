# Utilities for working on GHC.
{ pkgs, inputs, ... }:
let
  hadrianUtil = inputs.hadrian-util.packages.${pkgs.stdenv.hostPlatform.system}.default;
  hadrianUtilZshCompletion = pkgs.runCommandLocal "hadrian-util-zsh-completion" {
    nativeBuildInputs = [ hadrianUtil ];
  } ''
    mkdir -p $out/share/zsh/site-functions
    ${hadrianUtil}/bin/hadrian-util --zsh-completion-script ${hadrianUtil}/bin/hadrian-util > $out/share/zsh/site-functions/_hadrian-util
  '';
in
{
  home.packages = [
    hadrianUtil
    hadrianUtilZshCompletion
  ];

  programs.zsh = {
    shellAliases.hu = "hadrian-util";
    initContent = ''
      compdef _hadrian-util hu=hadrian-util
    '';
  };
}
