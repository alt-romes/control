{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.fetch-gitlab =
      let
        hlib = pkgs.haskell.lib;
        src = inputs.fetch-gitlab;
        hpkgs = pkgs.haskellPackages.override {
          overrides = self: _: {
            gitlab-haskell = hlib.dontCheck (self.callCabal2nix "gitlab-haskell" "${src}/vendor/gitlab-haskell" { });
          };
        };
      in
      hlib.justStaticExecutables (hlib.dontCheck (hpkgs.callCabal2nix "fetch-gitlab" src { }));
  };
}
