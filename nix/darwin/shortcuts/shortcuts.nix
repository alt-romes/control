{ lib, pkgs }:
let
  # Get all the *.shortcut files from the folder
  shortcutsDir = ./.;
  shortcutFiles = builtins.filter (f: lib.hasSuffix ".shortcut" f)
                    (builtins.attrNames (builtins.readDir shortcutsDir));

  mkShortcutDeriv = fileName:
    let
      # Drop .shortcut suffix
      shortcutName = "romes: ${lib.removeSuffix ".shortcut" fileName}";
      binName = lib.strings.toLower (lib.strings.sanitizeDerivationName shortcutName);
    in
    pkgs.writeShellScriptBin binName ''
        if ! shortcuts list | grep -Fxq "${shortcutName}"; then
          echo "Shortcut '${shortcutName}' not found. Trying to install from source..." >&2
          echo "Installing from backup version: \"${shortcutsDir}/${fileName}\"."
          echo "Please confirm this shortcut is up to date with what it should be doing."
          echo "--------------------------------------------------------------------------------"
          echo "IMPORTANT: Please rename the shortcut to add the 'romes: ' suffix."
          echo "--------------------------------------------------------------------------------"
          open "${shortcutsDir}/${fileName}"
          read -p "Press any key to continue" -n 1 -s
        fi

        if [ -z "$1" ]; then
          shortcuts run "${shortcutName}"
        else
          if [ -f "$1" ]; then
            shortcuts run "${shortcutName}" -i "$1"
          else
            SHORTCUT_INPUT_TMP="$(mktemp -d)/input"
            echo "$1" > "$SHORTCUT_INPUT_TMP"
            shortcuts run "${shortcutName}" -i "$SHORTCUT_INPUT_TMP"
          fi
        fi
    '';
in
{
  inherit mkShortcutDeriv;
} // builtins.listToAttrs (map (fileName: {
    name = lib.strings.sanitizeDerivationName (lib.removeSuffix ".shortcut" fileName);
    value = mkShortcutDeriv fileName;
  }) shortcutFiles)
