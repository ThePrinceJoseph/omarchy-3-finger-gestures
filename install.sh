#!/usr/bin/env bash
# Installs Omarchy 3 Finger Gestures into your Omarchy config.
# Safe to rerun (updates the files in place). Undo with ./uninstall.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hypr="$HOME/.config/hypr"
plugins="$HOME/.config/omarchy/plugins"
id="threefinger.minimized-tray"

for cmd in hyprctl omarchy omarchy-shell; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' not found; this needs Omarchy 4 with the Omarchy shell." >&2; exit 1; }
done
[[ -f "$hypr/hyprland.lua" ]] || { echo "error: $hypr/hyprland.lua not found; this needs Omarchy's Lua Hyprland config (Omarchy 4+)." >&2; exit 1; }

stamp=$(date +%s)
cp "$hypr/hyprland.lua" "$hypr/hyprland.lua.bak.$stamp"
echo "backed up hyprland.lua -> hyprland.lua.bak.$stamp"

install -m 644 "$here/hypr/minimize.lua" "$here/hypr/gestures.lua" "$hypr/"
echo "installed $hypr/minimize.lua and $hypr/gestures.lua"

# Load our modules after everything else in hyprland.lua (minimize first, so
# gestures.lua can see the Minimize table).
for mod in minimize gestures; do
  line="require(\"hypr.$mod\")"
  if ! grep -qF "$line" "$hypr/hyprland.lua"; then
    printf '\n%s\n' "$line" >> "$hypr/hyprland.lua"
    echo "added $line to hyprland.lua"
  fi
done

mkdir -p "$plugins/$id"
install -m 644 "$here/plugins/$id/manifest.json" "$here/plugins/$id/Tray.qml" "$plugins/$id/"
echo "installed tray plugin -> $plugins/$id"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy plugin enable "$id" >/dev/null 2>&1 || omarchy-shell shell enablePlugin "$id" '{}' >/dev/null 2>&1 || true
# The shell keeps an old copy of a reloaded plugin around; a restart makes sure
# the freshly installed one answers.
omarchy restart shell >/dev/null 2>&1 || true

hyprctl reload >/dev/null
errors=$(hyprctl configerrors)
if [[ -n "$errors" && "$errors" != "ok" ]]; then
  echo "Hyprland reported config errors:" >&2
  echo "$errors" >&2
  exit 1
fi

cat <<MSG

Done. Try it:
  three fingers left/right   change workspace
  three fingers down         minimize the focused window into the bottom tray
  three fingers up           bring the selected tile back (Left/Right pick, Enter restores, Esc lets go)
  SUPER+M                    hand the keyboard to the tray / take it back

Settings: the 'opt' table at the top of $hypr/gestures.lua
Uninstall: $here/uninstall.sh
MSG
