{ self, ...}:
{
  perSystem = { ... }: {
    fukusuke-vm =
      self.nixosConfigurations.fukusuke.config.microvm.declaredRunner;
  };
}
