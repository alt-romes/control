{ self, ... }:
{
  # Programs run on a timer, kept running, or in reaction to control-events,
  # as launchd user agents logging to /tmp/org.romes.<name>.{out,err}.log.
  flake.darwinModules.automations = { config, lib, pkgs, ... }:
    let
      inherit (lib) mkOption types;
      control-events = lib.getExe config.services.control-events-node.package;
      log = name: kind: "/tmp/org.romes.${name}.${kind}.log";

      reactions = lib.filterAttrs (_: a: a.on != null) config.automations;
      agents    = lib.filterAttrs (_: a: a.on == null) config.automations;

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

      reactionsConfig = pkgs.writeText "reactions.json" (builtins.toJSON (lib.mapAttrsToList (name: a: {
        inherit name;
        inherit (a) on topic;
        run = "${program name a}";
      }) reactions));
    in
    {
      options.automations = mkOption {
        default = { };
        type = types.attrsOf (types.submodule ({ name, ... }: {
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
              default = name;
              description = ''
                Report runs as `script/<topic>` events (`healthcheck/<topic>` if
                kept alive), a reaction's reacting to its cause. Null if the
                script reports on its own.
              '';
            };
            expected = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "The next run is expected within this many seconds.";
            };
          };
        }));
      };

      config.assertions = lib.mapAttrsToList (name: a: {
        assertion = lib.count lib.id [ (a.on != null) (a.every != null) (a.at != null) a.keepAlive ] <= 1;
        message = "automations.${name}: set at most one of on, every, at and keepAlive.";
      }) config.automations;

      config.launchd.user.agents = lib.mapAttrs (name: a: {
        serviceConfig = {
          ProgramArguments = reported name a;
          RunAtLoad = a.keepAlive;
          KeepAlive = a.keepAlive;
          StandardOutPath = log name "out";
          StandardErrorPath = log name "err";
        } // lib.optionalAttrs (a.every != null) { StartInterval = a.every; }
          // lib.optionalAttrs (a.at != null) { StartCalendarInterval = a.at; };
      }) agents // lib.optionalAttrs (reactions != { }) {
        reactions.serviceConfig = {
          ProgramArguments = [ control-events "healthcheck" "reactions" "--"
                               (lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.reactions) "${reactionsConfig}" ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = log "reactions" "out";
          StandardErrorPath = log "reactions" "err";
        };
      };
    };
}
