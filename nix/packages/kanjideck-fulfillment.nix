{ inputs, ... }:
{
  perSystem = { pkgs, system, ... }: {
    packages.kanjideck-fulfillment =
    let
      hpkgs = pkgs.haskellPackages.override {
        overrides = self: super: {
          cob = self.callCabal2nix "cob" inputs.cob-hs { };
          control-events = inputs.control-events.packages.${system}.default;
          streamly = self.streamly_0_11_0;
          streamly-core = self.streamly-core_0_3_0;
        };
      };
    in pkgs.haskell.lib.dontCheck (hpkgs.callCabal2nix "kanjideck-fulfillment" inputs.kanjideck-fulfillment { });
  };
}
