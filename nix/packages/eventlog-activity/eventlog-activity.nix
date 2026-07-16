{ ... }:
{
  perSystem = { pkgs, ... }: {
    packages.eventlog-activity =
    let
      hpkgs = pkgs.haskellPackages;
    in
      # justStaticExecutables keeps GHC out of the runtime closure; the cairo
      # backend's system libs (cairo/pango/fontconfig) are pulled in by the
      # Chart-cairo Haskell package itself.
      pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "eventlog-activity" ./. { });
  };
}
