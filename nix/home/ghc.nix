# Utilities for working on GHC.
{ pkgs, ... }:
let
  hadrianScript = pkgs.writeShellScriptBin "hadrian" ''
    set -euo pipefail

    flavour=""
    record_file="_build/flavour.txt"
    recorded_flavour=""

    if [[ -f "$record_file" ]]; then
      recorded_flavour="$(sed -n '1p' "$record_file")"
    fi

    if [[ "''${1-}" == --flavour=* ]]; then
      flavour="''${1#--flavour=}"
      shift
    fi

    if [[ -z "$flavour" ]]; then
      flavour="$recorded_flavour"
    elif [[ -n "$recorded_flavour" && "$flavour" != "$recorded_flavour" ]]; then
      echo "hadrian: requested flavour '$flavour' does not match flavour '$recorded_flavour' recorded in '$record_file'" >&2
      exit 1
    fi

    if [[ -z "$flavour" ]]; then
      echo "hadrian: no build flavour recorded in _build/flavour.txt" >&2
      echo "hadrian: pass a specific flavour, for example: hadrian --flavour=default test" >&2
      exit 1
    fi

    mkdir -p _build
    printf '%s\n' "$flavour" > "$record_file"

    exec ./hadrian/build -j "--flavour=$flavour" "$@"
  '';

  hadrianTestCommandScript = pkgs.writeShellScriptBin "hadrian-test-command" ''
    set -euo pipefail

    mapfile -t matches < <(
      awk '
        /^[[:space:]]*cd ".*" &&/ {
          line = $0
          sub(/[[:space:]]*<$/, "", line)
          print line
        }
      '
    )

    if [[ ''${#matches[@]} -eq 0 ]]; then
      echo "hadrian-test-command: no testsuite command found" >&2
      exit 1
    fi

    last_index=$((''${#matches[@]} - 1))
    printf '%s\n' "''${matches[$last_index]}"
  '';
in
{
  home.packages = [
    hadrianScript
    hadrianTestCommandScript
  ];
}
