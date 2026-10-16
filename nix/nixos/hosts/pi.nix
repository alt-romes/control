# Raspberry Pi Zero W V1.1 (armv6l, cross-compiled from aarch64-linux linux-builder)
#
# First install:
#   nix build '.?submodules=1#nixosConfigurations.pi.config.system.build.sdImage'
#   zstd -d result/sd-image/*.img.zst -o pi.img && sudo diskutil unmountDisk /dev/<diskname> && dd if=pi.img of=/dev/<diskname> bs=4M (CAREFUL!!!)
#   Then add `wifi.conf` to the FIRMWARE partition:
#     network={
#       ssid="..."
#       psk="..."
#     }
# Deploy:
#   nixos-rebuild switch --flake '.?submodules=1#pi' --target-host root@192.168.68.10 # or whichever ip
{ self, inputs, ... }:
{
  flake.images.pi = self.nixosConfigurations.pi.config.system.build.sdImage;
  flake.nixosConfigurations.pi = inputs.nixpkgs.lib.nixosSystem {
    modules = [ ({ config, lib, pkgs, modulesPath, ... }:
    let
      supvan = pkgs.rustPlatform.buildRustPackage {
        pname = "supvan-cups";
        version = "unstable";
        src = inputs.supvan-cups;
        cargoLock.lockFile = "${inputs.supvan-cups}/Cargo.lock";
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.dbus ];
        doCheck = false;
      };
    in {
      imports = [
        inputs.control-events.nixosModules.control-events
        (modulesPath + "/installer/sd-card/sd-image.nix")
        (modulesPath + "/profiles/minimal.nix")
      ];

      nixpkgs.buildPlatform = "aarch64-linux";
      nixpkgs.hostPlatform = "armv6l-linux"; # Raspberry Pi Zero W 1.1

      boot.loader.grub.enable = false;
      boot.loader.generic-extlinux-compatible.enable = true;
      boot.kernelPackages = pkgs.linuxPackages; # mainline, bcm2835_defconfig
      # only add strictly necessary modules
      hardware.enableAllHardware = lib.mkForce false;
      boot.initrd.includeDefaultModules = false;
      boot.initrd.kernelModules = [ "ext4" "mmc_block" ];
      boot.initrd.systemd.tpm2.enable = false;
      system.disableInstallerTools = true; # nixos-generate-config pulls bcachefs-tools, which fails on armv6l
      services.lvm.enable = false;
      boot.bcache.enable = false;
      boot.kexec.enable = false;
      fonts.fontconfig.enable = false;
      security.sudo.enable = false;

      sdImage.populateFirmwareCommands = ''
        (cd ${pkgs.raspberrypifw}/share/raspberrypi/boot && cp bootcode.bin fixup*.dat start*.elf *.dtb $NIX_BUILD_TOP/firmware/)
        cp ${pkgs.ubootRaspberryPiZero}/u-boot.bin firmware/u-boot.bin
        printf 'kernel=u-boot.bin\nenable_uart=1\navoid_warnings=1\n' > firmware/config.txt
      '';
      sdImage.populateRootCommands = ''
        mkdir -p ./files/boot
        ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
      '';

      fileSystems."/boot/firmware".options = lib.mkForce [ "nofail" ];
      systemd.services.wpa_supplicant.unitConfig.RequiresMountsFor = "/boot/firmware";

      hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];
      # Firmware's WPA handshake offload times out on our APs; let wpa_supplicant do it
      boot.extraModprobeConfig = "options brcmfmac feature_disable=0x82000";
      networking.wireless.enable = true;
      networking.wireless.extraConfigFiles = [ "/boot/firmware/wifi.conf" ];

      networking.hostName = "pi";
      networking.firewall.allowedTCPPorts = [ 1883 8631 ];
      networking.firewall.allowedUDPPorts = [ 5353 ];

      # Wireguard: place a private key (`wg genkey`) at the path below by hand,
      # and add its public key as a peer on the macmini.
      networking.wg-quick.interfaces.wg0 = {
        autostart = true;
        address = [ "10.0.0.6/32" ];
        privateKeyFile = "/var/lib/wireguard/private.key";
        peers = [
          # wireguard-macmini
          {
            publicKey = "hroqsfMWbBsCYhZTiPLNeE/3AK+AdBV3Zn16EJspPX8=";
            allowedIPs = [ "10.0.0.1/32" ];
            endpoint = "192.168.68.137:55902";
          }
        ];
      };

      services.control-events-node = {
        enable  = true;
        proxyTo = "10.0.0.1"; # macmini on wireguard VPN
        nodeId  = "pi-zero-w";
        system-healthcheck = true;
        package = null; # control-events (Haskell) does not build for armv6l
      };

      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ romes@world"
      ];
      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      hardware.bluetooth.enable = true;
      # The app can't auto-pair without a BlueZ agent; pair new printers once by hand:
      #   bluetoothctl: pairable on; agent NoInputNoOutput; default-agent; scan on;
      #                 pair <MAC>; trust <MAC>
      #   systemctl restart supvan-printer-app
      # Then add it on the mac with
      #   lpadmin -p supvan -E -v ipp://<pi-ip>:8631/ipp/print/<name> -m everywhere
      # where <name> is listed at http://<pi-ip>:8631/
      systemd.services.supvan-printer-app = {
        wantedBy = [ "multi-user.target" ];
        after = [ "bluetooth.target" "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = "${supvan}/bin/supvan-printer-app";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };

      system.stateVersion = "26.11";
    }) ];
  };
}
