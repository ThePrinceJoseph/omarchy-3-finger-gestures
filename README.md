# Omarchy 3 Finger Gestures

Three-finger touchpad gestures for [Omarchy](https://omarchy.org) 4, packaged as an
Omarchy shell plugin:

| Gesture | What happens |
|---|---|
| **Three fingers left / right** | Change workspace. The screen follows your fingers and glides into place when you let go. |
| **Three fingers down** | *Minimize* the focused window: it shrinks down into a tray along the bottom of the screen. |
| **Three fingers up** | Bring the selected minimized window back onto the workspace you are on now, growing up from the bottom edge. |

The tray shows one tile per minimized window (a picture of the window, its app icon,
title and a ✕) and only exists while something is minimized. Hover a tile to select
it, click it to bring it back. When a tile lands, the tray takes the keyboard:
**Left / Right** pick a tile, **Enter** brings it back, **Backspace** closes it,
**Escape** (or Down, or SUPER+M) hands the keyboard back. **SUPER+M** hands it to the
tray again later. It holds five windows by default (up to twelve): the idea is a quick
way to carry a few windows to another workspace, not a window list.

Hyprland has no real "minimize", so the tray is backed by a hidden special workspace
(`special:minimized`, separate from Omarchy's SUPER+S scratchpad). Maximized and
fullscreen windows come back maximized and fullscreen.

## Requirements

- Omarchy 4.x: the Lua Hyprland config (`~/.config/hypr/hyprland.lua`) and the Omarchy
  shell (Quickshell). Built and tested on Omarchy 4.0.4 / Hyprland 0.56.2.
- A touchpad that reports three fingers. Check with `python3 check-touchpad.py`
  (needs `sudo` or membership of the `input` group).
- `grim` for thumbnails (Omarchy ships it).

## Install

```bash
omarchy plugin add https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures.git --enable
```

That clones the plugin into `~/.config/omarchy/plugins/threefinger.gestures/` and
puts its 󱂬 button in the bar. The button installs the Hyprland side by itself: two Lua
files in `~/.config/hypr/`, a generated settings file, and a marked block at the end of
`hyprland.lua` that loads them. Nothing under `/usr/share/omarchy` is touched.

From a local checkout, `./install.sh` does the same by copying the folder into place.
Update with `omarchy plugin update threefinger.gestures`; remove with
`omarchy plugin remove threefinger.gestures` or the plugin's `uninstall.sh`, which
brings back anything still in the tray first.

## Settings

Click the 󱂬 button in the bar. Every setting is also a one-liner:

```bash
omarchy bar set threefinger.gestures tray_max 8
```

| Key | Default | Meaning |
|---|---|---|
| `minimize` | `true` | The down/up gestures and the tray. `false` for the workspace swipe only. |
| `swipe_distance` | `500` | Higher = the screen follows your fingers more slowly. |
| `swipe_cancel_ratio` | `0.12` | How much of a swipe commits to the next workspace. Lower = less. |
| `swipe_min_speed_to_force` | `25` | A flick faster than this commits regardless of distance. |
| `slide_speed` | `4.5` | Glide speed after you let go. Lower = slower. `0` leaves Omarchy's animations alone. |
| `instant_keyboard_switch` | `true` | Keep SUPER+1..0 instant even though swiping glides. |
| `persistent_workspaces` | `5` | Keep workspaces 1..N alive so a swipe visits each one in order and never creates new ones past N. A workspace above N that already has a window stays reachable. `0` to disable. |
| `tray_key` | `"SUPER + M"` | Key that toggles the tray's keyboard. `none` for no key. |
| `tray_max` | `5` | How many windows the tray holds, 1 to 12. Swipe down on a full tray shows a notification. |
| `tray_thumbnails` | `true` | A picture of each window in its tile, taken as it minimizes. |
| `tray_height` | `0` | Pixels. `0` picks 72 with thumbnails, 40 without. |
| `tray_reserve_space` | `false` | `true` makes tiled windows shrink to make room for the tray. `false` floats it over the bottom edge and nothing else moves. |

Settings live in the plugin's entry in `~/.config/omarchy/shell.json`. The generated
`~/.config/hypr/gestures-settings.lua` is rewritten from them; do not edit it by hand.
The shrink/grow duration (`anim_ms`) sits at the top of `minimize.lua`, matched to
Omarchy's window animation speed.

## Good to know

- **The tray takes the keyboard on purpose.** Right after a swipe down, typing goes to
  the tray until you press Escape. If you would rather it never grabbed the keyboard,
  remove the `else if (newest) root.focusMode = true` line in `Tray.qml`.
- **Why 5, and at most 12.** Tiles share the screen width and titles shrink to fit: on a
  1280-wide screen five tiles keep about 22 characters of title, twelve are down to a
  picture and an icon.
- **Thumbnails cost a moment.** The window is photographed before it starts to move,
  which delays the shrink by 30 to 110 ms depending on window size. Turn thumbnails off
  if you would rather have the instant start.
- **A sloppy diagonal swipe** can be read as the other axis. If down/up misfire or feel
  too eager, add `scale = 1.5` (or another value) to those two `hl.gesture` lines in
  `gestures.lua`.
- **Hyprland cannot unbind a gesture.** The first registration of an axis wins. The
  require block is added last so a three-finger gesture you wrote yourself in
  `input.lua` quietly takes precedence over these.
- **Editing the QML** hot-reloads, but the shell sometimes keeps the old copy
  answering. `omarchy restart shell` fixes that.
- **Something stuck in the hidden workspace?** This brings everything back, properly
  sized and tiled:

  ```bash
  hyprctl dispatch "(function() Minimize.restore_all() return hl.dsp.no_op() end)()"
  ```
- **Hyprland reloaded mid-animation?** Each window carries its saved state as a tag, and
  `minimize.lua` puts any stranded window straight back in place the next time it loads.

## How it works

**Left and right: workspace swipe.** This one is native to Hyprland. `gestures.lua`
registers a three-finger horizontal gesture with the built-in `workspace` action, so
Hyprland itself tracks your fingers and slides the workspace with them. The settings tune
how far you have to move, how little of a swipe commits, and how fast a flick counts.
Omarchy ships with the workspace slide animation turned off, so the config turns it back
on, which is what gives the glide after you let go. The SUPER+1..0 keys switch that
animation off for a split second so keyboard switches stay instant.

**Down: minimize.** Hyprland has no minimize, so `minimize.lua` fakes it. If thumbnails
are on, `grim` photographs the window first. Then the window is floated and, in the same
event, aimed at a short strip at the bottom edge; Hyprland animates the whole way, and
neighbours re-tile in step. Once it lands, the window is moved to the hidden special
workspace `minimized`. Special workspaces are invisible, skipped by the horizontal
swipe, and separate from the SUPER+S scratchpad. (Simply moving a window to another
workspace only fades it, which is why the float-and-shrink detour exists.)

**The tray.** `Tray.qml` is an Omarchy shell panel that watches Hyprland's window list
(`hyprctl clients -j`, refreshed on window events). When anything sits in the hidden
workspace, it shows a bottom panel with one tile per window. Hovering or arrowing to a
tile writes that window's address to `~/.local/state/omarchy/minimized-tray-selected`.

**Up: restore.** The swipe-up handler reads that state file, picks that window, and puts
the strip back on your current workspace. A tiled window is handed straight back to the
layout, one motion from the tray into its slot; floating, maximized and fullscreen
windows grow to their old geometry first and finalize once settled (Hyprland drops a
maximize requested within ~150 ms of a workspace move).

**The glue.** The minimize logic is a global Lua table (`Minimize`) inside Hyprland's
own Lua runtime. The gestures call it directly, and the tray calls the same functions
through `hyprctl dispatch`. Hyprland forgets its Lua state on every config reload, so
each window's original size and tiled/maximized state is also written onto the window as
a tag (`min_...`), which survives reloads. `Widget.qml` owns the settings: it persists
them in shell.json and runs `threefinger-apply`, which generates the Lua settings file
and reloads Hyprland.

## License

MIT. See `LICENSE`.
