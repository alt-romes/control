{ self, inputs, ... }:
let
  # The automations option, for both nix-darwin and home-manager
  common = { config, lib, ... }:
    let inherit (lib) mkOption types; in
    {
      options.automations = mkOption {
        default = { };
        type = types.attrsOf (types.submodule {
          options = {
            script = mkOption {
              type = types.lines;
              description = "The shell script to run.";
            };
            path = mkOption {
              type = types.listOf types.package;
              default = [ ];
              description = "Packages added to the script's PATH.";
            };
            environment = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Environment variables the script runs with.";
            };
            every = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Run every this many seconds.";
            };
            at = mkOption {
              type = types.nullOr (types.either types.attrs (types.listOf types.attrs));
              default = null;
              example = { Weekday = 0; Hour = 23; Minute = 0; };
              description = "Run at these times, as launchd's StartCalendarInterval.";
            };
            keepAlive = mkOption {
              type = types.bool;
              default = false;
              description = "Keep it running, starting it at load and again whenever it exits.";
            };
            runAtLoad = mkOption {
              type = types.bool;
              default = false;
              description = "Also run when loaded, e.g. at login.";
            };
            on = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "server/kanjideck/fulfillment-server/paid-order";
              description = ''
                A control-events filter: run once per completed event matching
                it, with the event as JSON on stdin (`{event, start, finished}`).
              '';
            };
            topic = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Report runs as `script/<topic>` events (`healthcheck/<topic>` if
                kept alive), a reaction's reacting to its cause. Null for none,
                e.g. if the script reports on its own.
              '';
            };
            expected = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "The next run is expected within this many seconds.";
            };
          };
        });
      };

      config.assertions = lib.mapAttrsToList (name: a: {
        assertion = lib.count lib.id [ (a.on != null) (a.every != null) (a.at != null) a.keepAlive ] <= 1;
        message = "automations.${name}: set at most one of on, every, at and keepAlive.";
      }) config.automations;
    };

  # The launchd agents' plists by name, with the automations reacting to
  # events all run by the one named `reactions`.
  agents = { lib, pkgs, automations, reactions }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      control-events = lib.getExe inputs.control-events.packages.${system}.control-events;
      log = name: kind: "/tmp/org.romes.${name}.${kind}.log";

      reacting  = lib.filterAttrs (_: a: a.on != null) automations;
      scheduled = lib.filterAttrs (_: a: a.on == null) automations;

      # Use getExe of writeShellScriptBin to make the binary itself not have a
      # hash in its name, so it doesn't show up in Login Items every time we rebuild.
      launcher = name: args: [ (lib.getExe (pkgs.writeShellScriptBin name "exec ${lib.escapeShellArgs args}")) ];

      program = name: a: pkgs.writeShellScript name ''
        ${lib.optionalString (a.on != null) "exec >>${log name "out"} 2>>${log name "err"}"}
        ${lib.optionalString (a.path != [ ]) "export PATH=${lib.makeBinPath a.path}:$PATH"}
        ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") a.environment)}
        ${a.script}
      '';

      reported = name: a:
        if a.topic == null then [ "${program name a}" ]
        else [ control-events (if a.keepAlive then "healthcheck" else "script") ]
          ++ lib.optionals (a.expected != null) [ "--expected" (toString a.expected) ]
          ++ [ a.topic "--" "${program name a}" ];

      reactionsConfig = pkgs.writeText "${reactions}.json" (builtins.toJSON (lib.mapAttrsToList (name: a: {
        inherit name;
        inherit (a) on topic;
        run = "${program name a}";
      }) reacting));
    in
    lib.mapAttrs (name: a: {
      ProgramArguments = launcher name (reported name a);
      RunAtLoad = a.keepAlive || a.runAtLoad;
      KeepAlive = a.keepAlive;
      StandardOutPath = log name "out";
      StandardErrorPath = log name "err";
    } // lib.optionalAttrs (a.every != null) { StartInterval = a.every; }
      // lib.optionalAttrs (a.at != null) { StartCalendarInterval = a.at; }
    ) scheduled // lib.optionalAttrs (reacting != { }) {
      ${reactions} = {
        ProgramArguments = launcher reactions [ control-events "healthcheck" reactions "--"
                                                (lib.getExe self.packages.${system}.reactions) "${reactionsConfig}" ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = log reactions "out";
        StandardErrorPath = log reactions "err";
      };
    };
in
{
  # Programs run on a timer, kept running, or in reaction to control-events,
  # as launchd user agents logging to /tmp/org.romes.<name>.{out,err}.log.
  flake.darwinModules.automations = { config, lib, pkgs, ... }: {
    imports = [ common ];

    # Also checks the automations of home-manager users, which can't see the system
    config.assertions =
      let
        all = lib.foldl' (a: u: a // (u.automations or { })) config.automations
                (lib.attrValues (config.home-manager.users or { }));
        evented = lib.attrNames (lib.filterAttrs (_: a: a.topic != null || a.on != null) all);
      in [{
        assertion = evented == [ ] || config.services.control-events-node.enable;
        message = "automations ${toString evented} use control-events, but services.control-events-node isn't enabled.";
      }];

    config.launchd.user.agents = lib.mapAttrs (_: plist: { serviceConfig = plist; })
      (agents { inherit lib pkgs; inherit (config) automations; reactions = "reactions"; });
  };

  flake.homeModules.automations = { config, lib, pkgs, ... }: {
    imports = [ common ];
    # TODO: To support automations on home-manager's modules backed by a NixOS
    # system, we'd need to have a NixOS "backend" and use home-manager's
    # systemd.user.services and systemd.user.timers.
    # Currently, using `automations` with the home-manager module only activates them on macOS.
    config.launchd.agents = lib.mapAttrs (_: plist: { enable = true; config = plist; })
      (agents { inherit lib pkgs; inherit (config) automations; reactions = "home-reactions"; });
  };
}
