# Notes

Previously we used flakes, which looked like this:

* Update flake deps with `nix flake update`
* Apply system configuration
    ```
    darwin-rebuild switch --flake $HOME/control/nix/darwin/
    ```

Installing existing configuration on a new computer:

```
nix run nix-darwin -- switch --flake github:my-user/my-repo#my-config
```

# Interacting with linux-builder

You can launch the linux builder standalone as:
```
nix run nixpkgs#darwin.linux-builder
```

The linux builder is launched as a daemon with `launchd`.

- Get info with `sudo launchctl print system/org.nixos.linux-builder`
- Info of running services `sudo launchctl list | grep nixos`
- How to stop it? `launchctl stop` commands didn't really work, it comes back!
    - We should probably disable it by default and only enable when needed.
- How to ssh to it? Perhaps better alternative is to build a nixos VM and ssh to
    that one.

# References

* https://nixcademy.com/posts/nix-on-macos/
* https://nixcademy.com/posts/macos-linux-builder/
* https://wiki.nixos.org/wiki/NixOS_virtual_machines_on_macOS
* https://www.tweag.io/blog/2023-02-09-nixos-vm-on-macos/
* NixOS in Production by Gabriella Gonzales

# Historical notes

Using vanilla channels didn't work for building the linux-builder when doing
`darwin-rebuild switch`. The flake does work.

