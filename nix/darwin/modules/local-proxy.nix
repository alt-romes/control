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

  config = {

    # 1. Use our local DNS Resolver
    # These two options basically amount to calling for each knownNetworkServices:
    # `networksetup -setdnsservers <knownNetworkService> <dns servers>
    networking.knownNetworkServices = [ "Wi-Fi" "Ethernet" ];
    networking.dns = [ "127.0.0.1" ];

    # 2. The local DNS Resolver (dnsmasq)
    services.dnsmasq = {
      enable = true;

      addresses = lib.mapAttrs (_name: entry: entry.host) cfg.hosts;

      # empty list means use the servers from /etc/resolv.conf as a fallback
      servers = [];
    };

    # 3. An HTTPS Reverse Proxy: DNS maps names to IPs, we need a way of mapping
    # names to specific ports too
    # (currently this is a custom module)
    services.caddy = {
      enable = true;
      virtualHosts = lib.mapAttrs
        (_name: entry: "${entry.host}:${toString entry.port}")
        cfg.hosts;
    };
  };
}
