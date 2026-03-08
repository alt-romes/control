{ config, lib, pkgs, ... }:
let
  cfg = config.services.local-proxy;
in
{

  imports = [
    ./caddy.nix
  ];

  options.services.local-proxy = {
    enable = lib.mkEnableOption "Automatic Local DNS and Caddy Reverse Proxy";

    hosts = lib.mkOption {
      description = "Attribute set of local domains mapping to hosts and ports.";
      default = {};
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "The target IP to proxy to.";
          };
          port = lib.mkOption {
            type = lib.types.int;
            description = "The target port to proxy to.";
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = lib.all
          (name: lib.hasSuffix ".localhost" name)
          (lib.attrNames cfg.hosts);
        message = "All local-proxy host names must end in .localhost, since we don't do DNS mapping, only reverse proxy on localhost (and .localhost names are automatically redirected to 127.0.01). Offending entries: "
          + lib.concatStringsSep ", "
              (lib.filter (n: !lib.hasSuffix ".localhost" n) (lib.attrNames cfg.hosts));
      }
    ];

    # "<name>.localhost" URLs are mapped to 127.0.0.1.
    # We use a reverse proxy to map the name to a particular host:port
    services.caddy = {
      enable = true;
      virtualHosts = lib.mapAttrs
        (_name: entry: "${entry.host}:${toString entry.port}")
        cfg.hosts;
    };
  };
}
