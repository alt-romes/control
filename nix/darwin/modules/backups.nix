# Backups on mac-mini; eg from mogbit
{ pkgs, config, ... }:
{
  
  # Create a user on this machine which mogbit can access to write backups
  users.users."mogbit-backups" = {
    uid = 4335;
    gid = config.users.groups."mogbit-backups".gid;
    shell = pkgs.zsh;
    packages = [ pkgs.borgbackup ]; # borgbackup required to do the backups!

    createHome = false;

    # NOTE: For remote access to work, Remote Login must be allowed in the
    # MacOS settings!!
    openssh.authorizedKeys.keys = [
      # public key from mogbit's backup keys
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKCkRdWpIj8qEIpmC25T/4bxCe1CMhQNfgTAPWN/YhZG"
    ];
  };
  users.groups."mogbit-backups" = {
    gid = 4334; # made up number for groupid
    members = [ "romes" ]; # hardcoded myself as part of this group
  };
  users.knownUsers  = [ "mogbit-backups" ];  # users managed by nix-darwin
  users.knownGroups = [ "mogbit-backups" ]; # groups managed by nix-darwin

  system.activationScripts.postActivation.text = ''
    mkdir -p /Users/mogbit-backups
    chown mogbit-backups:mogbit-backups /Users/mogbit-backups
    chmod 750 /Users/mogbit-backups
  '';
}
