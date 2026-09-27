# Omarchy 3 Finger Gestures

Public GitHub repo (github.com/ThePrinceJoseph/omarchy-3-finger-gestures): the
shareable version of the three-finger touchpad gestures built in
`../laptop-setup/` (workspace swipe, minimize-to-tray, restore).

## Layout

- `hypr/gestures.lua`: the gestures and all user settings (`opt` table)
- `hypr/minimize.lua`: minimize/restore logic (global `Minimize` table)
- `plugins/threefinger.minimized-tray/`: Omarchy shell plugin (Quickshell QML) for the bottom tray
- `install.sh` / `uninstall.sh`: copy into `~/.config`, wire up `hyprland.lua`, enable the plugin

## Rules

- This repo is the packaged copy. The laptop's own config in `~/.config/hypr/`
  (input.lua, minimize.lua, bindings.lua) and the `joey.minimized-tray` plugin
  are the originals; when they change, port the change here and vice versa.
- Test changes with the install script on this machine, then `hyprctl configerrors`
  and `quickshell log -p /usr/share/omarchy/shell -t 40` for the tray.
- Keep README's settings table in step with the `opt` table.
