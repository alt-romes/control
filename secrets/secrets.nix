# This secrets.nix file is not imported into your NixOS configuration. It's
# only used for the `agenix` CLI tool to know which public keys to use for
# encryption.

let
  # These are the users/systems that will be able to decrypt the .age files later
  # with their corresponding private keys. 
  # In 1Password, under Agenix SSH Keys
  romes-macmini = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOh7oeTq9ThSabXTQiRlJ2hZG499HdH6uBoxWUZ85xPu";
  romes-mbp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBuBXaTD+KVCC3+9xOL42MImerdQ6xEE4CCTJMwi4zr/";
  romes-machines = [ romes-macmini romes-mbp ];
in
{
  # To create or edit a secret file, run
  #   `nix run github:ryantm/agenix -- -e secret1.age --identity ~/.ssh/agenix`
  # in this directory
  # Since SSH_AUTH_SOCKET is broken, pass --identity ~/.ssh/agenix as well
  #
  # > In order to decrypt and open a .age file for editing you need the private
  # > key of one of the public keys it was encrypted with. You can pass the
  # > private key you want to use explicitly with -i, e.g.
  # - We store the agenix key in both machines under the same path
  #
  # See https://github.com/ryantm/agenix/issues/182
  "kimai.age".publicKeys = romes-machines;
  "duckdns.age".publicKeys = romes-machines;
  "wireguard-macmini.age".publicKeys = [ romes-macmini ]; # private key for macmini
  "wireguard-mbp.age".publicKeys = [ romes-mbp ]; # private key for mbp
  "remote-builder-key.age".publicKeys = [ romes-mbp ]; # mbp uses key to access remote builder (on mac mini)
}
