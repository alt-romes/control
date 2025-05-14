{
  config,
  lib,
  ...
}:
let
  cfg = config.services.duckdns;
in
{

  options = {

    services.duckdns = with lib.types; {

      enable = lib.mkOption {
        default = false;
        type = bool;
        description = ''
          Whether to synchronise your machine's IP address with duckdns.
        '';
      };

      domains = lib.mkOption {
        default = [ "" ];
        type = listOf str;
        description = ''
          Domain name(s) to synchronize (without duckdns.org suffix).
        '';
      };

      passwordFile = lib.mkOption {
        default = null;
        type = nullOr str;
        description = ''
          A file containing the password or a TSIG key in named format when using the nsupdate protocol.
        '';
      };

      interval = lib.mkOption {
        default = 1800; # every 30m
        type = int;
        description = ''
          The interval at which to run the check and update in seconds.
        '';
      };

    };
  };

  ###### implementation

  config = lib.mkIf config.services.duckdns.enable {

    launchd.daemons.duckdns = {
      script = ''
        # Read password file then invoke duckdns
        TOKEN=$(head -n 1 ${cfg.passwordFile} | tr -d '\n')
        echo url="https://www.duckdns.org/update?domains=${lib.concatStringsSep "," cfg.domains}&token=$TOKEN&ip=" | curl -k -o ~/duckdns/duck.log -K -
      '';
      serviceConfig = {
        Label = "Dynamic DNS Client";

        RunAtLoad = true;
        StartInterval = cfg.interval;

        StandardOutPath = "/tmp/nix.services.ddclient.out";
        StandardErrorPath = "/tmp/nix.services.ddclient.err";
      };
    };

  };
}

