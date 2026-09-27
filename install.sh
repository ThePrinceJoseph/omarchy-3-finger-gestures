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

# Code files: replaced on every run, with a backup whenever the installed copy
# differs (so nothing anyone edited by hand is lost).
for f in minimize.lua gestures.lua; do
  if [[ -f "$hypr/$f" ]] && ! cmp -s "$here/hypr/$f" "$hypr/$f"; then
    cp "$hypr/$f" "$hypr/$f.bak.$stamp"
    echo "backed up $f -> $f.bak.$stamp"
  fi
  install -m 644 "$here/hypr/$f" "$hypr/$f"
done
echo "installed $hypr/minimize.lua and $hypr/gestures.lua"

# Settings file: created once, never overwritten.
if [[ -f "$hypr/gestures-settings.lua" ]]; then
  echo "kept your $hypr/gestures-settings.lua"
else
  install -m 644 "$here/hypr/gestures-settings.lua" "$hypr/"
  echo "created $hypr/gestures-settings.lua (your settings live here)"
fi

# Load our modules after everything else in hyprland.lua (minimize first, so
# gestures.lua can see the Minimize table).
for mod in minimize gestures; do
  line="require(\"hypr.$mod\")"
  if ! grep -qE "^[[:space:]]*require\(\"hypr\.$mod\"\)" "$hypr/hyprland.lua"; then
    if [[ ! -f "$hypr/hyprland.lua.bak.$stamp" ]]; then
      cp "$hypr/hyprland.lua" "$hypr/hyprland.lua.bak.$stamp"
      echo "backed up hyprland.lua -> hyprland.lua.bak.$stamp"
    fi
    printf '\n%s\n' "$line" >> "$hypr/hyprland.lua"
    echo "added $line to hyprland.lua"
  fi
done

mkdir -p "$plugins/$id"
install -m 644 "$here/plugins/$id/manifest.json" "$here/plugins/$id/Tray.qml" "$plugins/$id/"
echo "installed tray plugin -> $plugins/$id"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
if ! omarchy plugin enable "$id" >/dev/null 2>&1; then
  omarchy-shell shell enablePlugin "$id" '{}' >/dev/null 2>&1 || true
fi
if ! omarchy plugin list --json 2>/dev/null | grep -q "\"id\": *\"$id\"[^}]*\"enabled\": *true"; then
  echo "error: the tray plugin '$id' is not enabled. Try: omarchy plugin enable $id" >&2
  exit 1
fi
# The shell keeps an old copy of a reloaded plugin around; a restart makes sure
# the freshly installed one answers.
if ! omarchy restart shell >/dev/null 2>&1; then
  echo "warning: 'omarchy restart shell' failed; run it yourself to load the tray." >&2
fi
# Wait for the tray to answer, so a broken plugin shows up here and not later.
tray_ok=0
for _ in $(seq 1 20); do
  if [[ "$(omarchy-shell minimized-tray count 2>/dev/null | tail -1)" =~ ^[0-9]+$ ]]; then tray_ok=1; break; fi
  sleep 0.5
done
if [[ $tray_ok -ne 1 ]]; then
  echo "error: the tray plugin did not start. Check: quickshell log -p /usr/share/omarchy/shell -t 40" >&2
  exit 1
fi

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

Settings: $hypr/gestures-settings.lua (kept across updates)
Uninstall: $here/uninstall.sh
MSG
