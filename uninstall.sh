#!/usr/bin/env bash
# Removes Omarchy 3 Finger Gestures. Any still-minimized windows are brought
# back to the current workspace first.
set -euo pipefail

hypr="$HOME/.config/hypr"
plugins="$HOME/.config/omarchy/plugins"
id="threefinger.minimized-tray"

# Rescue minimized windows before the tray goes away: a full restore (size,
# tiling, maximize) while minimize.lua is still loaded, else a plain move back.
hyprctl dispatch "(function()
  if Minimize and Minimize.restore_all then Minimize.restore_all() return hl.dsp.no_op() end
  for _, w in ipairs(hl.get_workspace_windows('special:minimized')) do
    hl.dispatch(hl.dsp.window.move({ window = w, workspace = '+0', follow = false }))
    hl.dispatch(hl.dsp.window.float({ window = w, action = 'disable' }))
  end
  return hl.dsp.no_op()
end)()" >/dev/null 2>&1 || true
sleep 1.5  # let the restore animations finish before the code goes away

if [[ -f "$hypr/hyprland.lua" ]]; then
  stamp=$(date +%s)
  cp "$hypr/hyprland.lua" "$hypr/hyprland.lua.bak.$stamp"
  sed -i '/^require("hypr\.minimize")$/d; /^require("hypr\.gestures")$/d' "$hypr/hyprland.lua"
  echo "removed the require lines from hyprland.lua (backup: hyprland.lua.bak.$stamp)"
fi
rm -f "$hypr/minimize.lua" "$hypr/gestures.lua" "$hypr/gestures-settings.lua"
rm -f "$HOME/.local/state/omarchy/minimized-tray-selected"

omarchy plugin disable "$id" >/dev/null 2>&1 || true
rm -rf "${plugins:?}/$id"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true

hyprctl reload >/dev/null 2>&1 || true
echo "Omarchy 3 Finger Gestures removed. Hyprland's built-in defaults are back."
