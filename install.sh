#!/usr/bin/env bash
# Installs 3 Finger Gestures as an Omarchy shell plugin from this checkout.
# The plugin then installs its own Hyprland side (threefinger-apply). If you
# cloned from GitHub you can skip this and use:
#   omarchy plugin add https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures.git --enable
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id="threefinger.gestures"
plugins="$HOME/.config/omarchy/plugins"
for cmd in hyprctl omarchy omarchy-shell jq; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' not found; this needs Omarchy 4 with the Omarchy shell." >&2; exit 1; }
done
[[ -f "$HOME/.config/hypr/hyprland.lua" ]] || { echo "error: ~/.config/hypr/hyprland.lua not found; this needs Omarchy's Lua Hyprland config." >&2; exit 1; }

target="$plugins/$id"
if [[ "$here" != "$target" ]]; then
  mkdir -p "$plugins"
  rm -rf "$target"
  mkdir -p "$target"
  # Everything but git metadata and backups.
  (cd "$here" && tar --exclude=.git --exclude='*.bak.*' -cf - .) | tar -xf - -C "$target"
  echo "copied plugin -> $target"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy plugin enable "$id" >/dev/null 2>&1 || omarchy-shell shell enablePlugin "$id" '{}' >/dev/null 2>&1 || true
if ! omarchy plugin list --json 2>/dev/null | grep -q "\"id\": *\"$id\"[^}]*\"enabled\": *true"; then
  echo "error: plugin '$id' is not enabled. Try: omarchy plugin enable $id" >&2; exit 1
fi
# Apply the Hyprland side now (the bar widget also does this on load).
"$target/threefinger-apply" --defaults
if ! omarchy restart shell >/dev/null 2>&1; then
  echo "warning: 'omarchy restart shell' failed; run it yourself to load the tray." >&2
fi
tray_ok=0
for _ in $(seq 1 20); do
  if [[ "$(omarchy-shell minimized-tray count 2>/dev/null | tail -1)" =~ ^[0-9]+$ ]]; then tray_ok=1; break; fi
  sleep 0.5
done
[[ $tray_ok -eq 1 ]] || { echo "error: the tray did not start. Check: quickshell log -p /usr/share/omarchy/shell -t 40" >&2; exit 1; }

cat <<MSG

Done. Try it:
  three fingers left/right   change workspace
  three fingers down         minimize the focused window into the bottom tray
  three fingers up           bring the selected tile back
  SUPER+M                    hand the keyboard to the tray / take it back

Settings: click the 󱂬 icon in the bar, or: omarchy bar set $id <key> <value>
Uninstall: $target/uninstall.sh
MSG
