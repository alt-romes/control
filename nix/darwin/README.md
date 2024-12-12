# Notes

* Update flake deps with `nix flake update`
* Apply system configuration `darwin-rebuild switch --flake .`, in this directory.

Installing on a new computer:

```
nix run nix-darwin -- switch --flake github:my-user/my-repo#my-config
```

# References

* https://nixcademy.com/posts/nix-on-macos/
* https://nixcademy.com/posts/macos-linux-builder/
* https://wiki.nixos.org/wiki/NixOS_virtual_machines_on_macOS
* https://www.tweag.io/blog/2023-02-09-nixos-vm-on-macos/
* NixOS in Production by Gabriella Gonzales

