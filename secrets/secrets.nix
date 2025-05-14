# This secrets.nix file is not imported into your NixOS configuration. It's
# only used for the `agenix` CLI tool to know which public keys to use for
# encryption.

let
  # These are the users/systems that will be able to decrypt the .age files later
  # with their corresponding private keys. 
  romes-macmini = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOh7oeTq9ThSabXTQiRlJ2hZG499HdH6uBoxWUZ85xPu";
  # romes-mbp = "...";
  romes-machines = [ romes-macmini ]; # ++ [ romes-mbp ]
in
{
  # To create or edit a secret file, run
  #   `nix run github:ryantm/agenix -- -e secret1.age --identity ~/.ssh/agenix`
  # in this directory
  # Since SSH_AUTH_SOCKET is broken, pass --identity ~/.ssh/agenix as well, for now (since that is the private key for the macmini pub key).
  # See https://github.com/ryantm/agenix/issues/182
  "kimai.age".publicKeys = romes-machines;
  "duckdns.age".publicKeys = romes-machines;

  # "secret1.age".publicKeys = [ user1 system1 ];
  # "secret2.age".publicKeys = users ++ systems;
}


