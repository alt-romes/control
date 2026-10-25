{ self, ... }:
{
  # Prints the shipping label of each paid Kanjideck order as it is fulfilled
  flake.darwinModules.kanjideck-label-printer = { pkgs, ... }: {
    launchd.user.agents.kanjideck-label-printer = {
      command = "${self.packages.${pkgs.stdenv.hostPlatform.system}.kanjideck-fulfillment}/bin/kanjideck-label-printer Supvan_T50M /var/tmp/kanjideck-labels";
      # weasyprint renders the labels, /usr/bin/lp prints them
      path = [ pkgs.python3Packages.weasyprint "/usr/bin" ];
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath   = "/tmp/org.romes.kanjideck-label-printer.out.log";
        StandardErrorPath = "/tmp/org.romes.kanjideck-label-printer.err.log";
      };
    };
  };
}
