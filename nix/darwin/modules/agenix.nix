{ inputs, ... }:
{
  flake.darwinModules.agenix = { pkgs, ... }: {

    modules = [
      inputs.agenix.darwinModules.default
    ];

    environment.systemPackages = [
      inputs.agenix.packages."${pkgs.stdenv.hostPlatform.system}".default
    ];

    # ------------------------------------------------------------------------
    # Agenix conf

    # While SSH_AUTH_SOCKET doesn't work, we need to download from 1Password the
    # key into this path to decrypt the secrets.
    # See https://github.com/ryantm/agenix/issues/182
    # once this made the switch fail; but re-running fixed it... it looked like a
    # race where the identity key wasn't ready yet.
    age.identityPaths = [ "/Users/romes/.ssh/agenix" ];

    # ------------------------------------------------------------------------
    # Agenix secrets

    # We list all ./agenix/secrets.nix secrets here. Whoever includes this
    # module can reference all secrets, but not all hosts can necessarily
    # decrypt them all (see ./agenix/secrets.nix).

    age.secrets.kimai = {
      file = ./agenix/kimai.age;
      # this secret will be accessed on home-manager activation and when used as a tool
      # so the user needs permissions
      owner = "romes";
    };

    age.secrets.duckdns.file = ./duckdns.age;

    age.secrets.wireguard-macmini.file     = ./wireguard-macmini.age;
    age.secrets.wireguard-mbp.file         = ./wireguard-mbp.age;
    age.secrets.wireguard-mercury-mbp.file = ./wireguard-mercury-mbp.age;

  };
}
