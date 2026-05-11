{ inputs, ... }:
{
  flake.darwinModules.agenix = { pkgs, ... }: {

    imports = [
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

  };
}
