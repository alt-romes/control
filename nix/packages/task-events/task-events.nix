{ self, inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.task-events =
    let
      hpkgs = pkgs.haskellPackages;
      control-events = pkgs.haskell.lib.dontCheck (hpkgs.callCabal2nix "control-events" inputs.control-events { });
    in pkgs.haskell.lib.justStaticExecutables
        (hpkgs.callCabal2nix "task-events" ./. { inherit control-events; });
  };

  flake.homeModules.task-events = { config, lib, pkgs, ... }: {
    options.programs.custom.task-events = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add a taskwarrior task for each mail to todo@mogbit.com, problem the
        dashboard announces, and trigger a run announces.
      '';
    };

    config.launchd.agents.task-events = lib.mkIf config.programs.custom.task-events {
      enable = true;
      config = {
        ProgramArguments = [ "${self.packages.${pkgs.stdenv.hostPlatform.system}.task-events}/bin/task-events" ];
        EnvironmentVariables.PATH = lib.makeBinPath [ config.programs.taskwarrior.package ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/task-events.log";
      };
    };
  };
}
