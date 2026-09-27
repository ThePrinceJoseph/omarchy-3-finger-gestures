# Omarchy 3 Finger Gestures

Public GitHub repo (github.com/ThePrinceJoseph/omarchy-3-finger-gestures). The repo
root *is* the Omarchy shell plugin (`manifest.json` at the top), so
`omarchy plugin add <url> --enable` installs it straight into
`~/.config/omarchy/plugins/threefinger.gestures/`.

## Layout

- `manifest.json`: plugin id `threefinger.gestures`, kinds bar-widget + panel, settings defaults/schema
- `Widget.qml`: bar button + settings popup; persists settings in shell.json and runs `threefinger-apply`
- `Tray.qml`: the bottom tray (panel kind, keepLoaded)
- `threefinger-apply`: writes `~/.config/hypr/gestures-settings.lua` from settings JSON, installs
  `hypr/*.lua` into `~/.config/hypr/`, ensures the marked require block, reloads Hyprland
- `threefinger-require`: adds/removes the `-- threefinger:begin/end` block in hyprland.lua
- `hypr/gestures.lua`: gestures + defaults; `hypr/minimize.lua`: minimize/restore/thumbnails (global `Minimize`)
- `check-touchpad.py`: how many fingers the touchpad tracks
- `install.sh` / `uninstall.sh`: for a local checkout (copies into the plugins dir)

## Rules

- This repo is the single source of truth. The laptop runs it via `./install.sh`
  (which copies the checkout into the plugins dir). Edit here, run `./install.sh`, commit, push.
- Settings are edited in the bar widget or with `omarchy bar set threefinger.gestures <key> <value>`;
  `gestures-settings.lua` is generated, never hand-edited.
- Test with `hyprctl configerrors`, `quickshell log -p /usr/share/omarchy/shell -t 40`, and the
  IPC helpers (`omarchy-shell minimized-tray count|selected|focused|layout|icon <class>|hitTestClose <i>`).
- The shell's hot-reload can leave a stale plugin instance answering IPC: `omarchy restart shell`.
