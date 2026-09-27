# Omarchy 3 Finger Gestures

Three-finger touchpad gestures for [Omarchy](https://omarchy.org) 4, packaged as an
Omarchy shell plugin:

| Gesture | What happens |
|---|---|
| **Three fingers left / right** | Change workspace. The screen follows your fingers and glides into place when you let go. |
| **Three fingers down** | *Minimize* the focused window: it shrinks down into a tray along the bottom of the screen. |
| **Three fingers up** | Bring the selected minimized window back onto the workspace you are on now, growing up from the bottom edge. |

The dock shows one tile per minimized window (a picture of the window, its app icon
and title) and only exists while something is minimized. Hover a tile for a ✕ and a
larger preview with the full title. Hover a tile to select
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

## Install

```bash
omarchy plugin add https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures.git --enable
```

That clones the plugin into `~/.config/omarchy/plugins/threefinger.gestures/` and
puts its 󱂬 button in the bar. The button installs the Hyprland side by itself: two Lua
files in `~/.config/hypr/`, a generated settings file, and a marked block at the end of
`hyprland.lua` that loads them. Nothing under `/usr/share/omarchy` is touched.

From a local checkout, `./install.sh` does the same by copying the folder into place.
Update with `omarchy plugin update threefinger.gestures`.

**To remove it, run the plugin's own script:**

```bash
~/.config/omarchy/plugins/threefinger.gestures/uninstall.sh
```

It brings back anything still in the dock, removes the Lua files and the require
block, and then removes the plugin. `omarchy plugin remove` on its own only deletes
the plugin folder; the gestures would notice the dock is gone and switch themselves
off with a warning, but the files would stay behind.

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
| `focus_blur` | `false` | While the dock has the keyboard, lightly blur and dim everything else. Empty workspaces stay clear. |
| `tray_reserve_space` | `false` | `true` makes tiled windows shrink to make room for the tray. `false` floats it over the bottom edge and nothing else moves. |

Settings live in the plugin's entry in `~/.config/omarchy/shell.json`. The generated
`~/.config/hypr/gestures-settings.lua` is rewritten from them; do not edit it by hand.
The shrink/grow duration (`anim_ms`) sits at the top of `minimize.lua`, matched to
Omarchy's window animation speed.

## Good to know

- **The dock takes the keyboard on purpose.** Right after a swipe down, typing goes to
  the dock until you press Escape. Turn on `focus_blur` to make that obvious: everything
  else on screen is lightly blurred and dimmed while the dock holds the keyboard; a workspace with no windows stays clear, since
  that is where the tiles are headed. Omarchy keeps blur off globally, so it is switched
  on only for that moment and your own blur settings are put back afterwards (strength:
  `M.scrim_blur` in `minimize.lua`). If you would rather it never grabbed the keyboard,
  remove the `else if (newest) root.focusMode = true` line in `Tray.qml`.
- **Why 5, and at most 12.** Tiles share the screen width and titles shrink to fit: on a
  1280-wide screen five tiles keep about 22 characters of title, twelve are down to a
  picture and an icon.
- **The flight starts about 60 ms after the swipe**, the time it takes to photograph the
  window before its picture takes off.
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
  `minimize.lua` puts any stranded window straight back the next time it loads, maximized
  or fullscreen again if it was.
- **Fullscreen windows.** The dock sits on the overlay layer, so it stays visible and
  clickable even while a fullscreen window is up. Restoring a maximized and a fullscreen
  window onto the same workspace at once can only keep one of them that way, since
  Hyprland allows one fullscreen window per workspace.
- **Several monitors.** Flights are drawn on the monitor the window is on, and a window
  restored onto a smaller monitor is fitted to it.

## How it works

**Left and right: workspace swipe.** This one is native to Hyprland. `gestures.lua`
registers a three-finger horizontal gesture with the built-in `workspace` action, so
Hyprland itself tracks your fingers and slides the workspace with them. The settings tune
how far you have to move, how little of a swipe commits, and how fast a flick counts.
Omarchy ships with the workspace slide animation turned off, so the config turns it back
on, which is what gives the glide after you let go. The SUPER+1..0 keys switch that
animation off for a split second so keyboard switches stay instant.

**Down: minimize.** Hyprland has no minimize, so `minimize.lua` fakes it. First the dock
photographs the window through the compositor's own window export, so the picture is the
window's buffer alone with nothing that happened to overlap it. Then the dock plugin animates that picture from the window's
rectangle down into the tile it is about to occupy, while the real window, hidden and
with its own animations off, slips into the hidden special workspace `minimized`.
Nothing is ever resized: what you see moving is the picture, so the content never
reflows mid-flight. Special workspaces are invisible, skipped by the horizontal swipe,
and separate from the SUPER+S scratchpad.

**The tray.** `Tray.qml` is an Omarchy shell panel that watches Hyprland's window list
(`hyprctl clients -j`, refreshed on window events). When anything sits in the hidden
workspace, it shows a bottom panel with one tile per window. Hovering or arrowing to a
tile writes that window's address to `~/.local/state/omarchy/minimized-tray-selected`.

**Up: restore.** The swipe-up handler reads that state file and picks that window. The
dock flies the picture from the tile back to where the window goes, while the real
window arrives on your workspace invisible, takes its place in the layout (the dock is
told the real spot so the picture lands exactly on it), and is revealed the moment the
picture lands. Maximized and fullscreen windows are un-maximized for the trip and
maximized again just before the reveal, because Hyprland hands a fullscreen state to a
neighbour if a fullscreen window changes workspace.

**The glue.** The minimize logic is a global Lua table (`Minimize`) inside Hyprland's
own Lua runtime. The gestures call it directly, and the dock calls the same functions
through `hyprctl dispatch`. Lua talks to the dock the other way through Hyprland's own
event socket (the `event` dispatcher), so no process is spawned on the way to the screen. Hyprland forgets its Lua state on every config reload, so
each window's original size and tiled/maximized state is also written onto the window as
a tag (`min_...`), which survives reloads. `Widget.qml` owns the settings: it persists
them in shell.json and runs `threefinger-apply`, which generates the Lua settings file
and reloads Hyprland.

## License

MIT. See `LICENSE`.
