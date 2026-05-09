{ self, ...}:
{
  perSystem = { ... }: {
    packages.fukusuke-vm =
      self.nixosConfigurations.fukusuke.config.microvm.declaredRunner;
  };
}
