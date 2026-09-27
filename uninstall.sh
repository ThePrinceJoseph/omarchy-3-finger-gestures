#!/usr/bin/env bash
# Removes 3 Finger Gestures. Windows still in the tray are brought back first.
set -uo pipefail
id="threefinger.gestures"
hypr="$HOME/.config/hypr"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

hyprctl dispatch "(function()
  if Minimize and Minimize.shutdown then Minimize.shutdown() return hl.dsp.no_op() end
  for _, w in ipairs(hl.get_workspace_windows('special:minimized')) do
    hl.dispatch(hl.dsp.window.move({ window = w, workspace = '+0', follow = false }))
    hl.dispatch(hl.dsp.window.float({ window = w, action = 'disable' }))
  end
  return hl.dsp.no_op()
end)()" >/dev/null 2>&1 || true
sleep 1.5

"$here/threefinger-require" --remove 2>/dev/null || true
rm -f "$hypr/minimize.lua" "$hypr/gestures.lua" "$hypr/gestures-settings.lua"
rm -f "$HOME/.local/state/omarchy/minimized-tray-selected" "$HOME/.local/state/omarchy/minimized-tray-settings.json"
rm -rf "$HOME/.cache/threefinger-tray"
hyprctl reload >/dev/null 2>&1 || true

omarchy plugin disable "$id" >/dev/null 2>&1 || true
if [[ "$here" == "$HOME/.config/omarchy/plugins/$id" ]]; then
  # Running from the installed copy: let the shell forget it, then remove the files.
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  cd / && rm -rf "$here"
else
  rm -rf "$HOME/.config/omarchy/plugins/$id"
fi
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true
echo "3 Finger Gestures removed. Hyprland's built-in defaults are back."
