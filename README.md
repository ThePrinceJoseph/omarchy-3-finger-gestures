# Omarchy 3 Finger Gestures

Three-finger touchpad gestures for [Omarchy](https://omarchy.org) 4:

| Gesture | What happens |
|---|---|
| **Three fingers left / right** | Change workspace. The screen follows your fingers and glides into place when you let go. |
| **Three fingers down** | *Minimize* the focused window: it shrinks down into a tray along the bottom of the screen. |
| **Three fingers up** | Bring the selected minimized window back onto the workspace you are on now, growing up from the bottom edge. |

The tray shows one tile per minimized window (app icon, title, a ✕ to close it) and
only exists while something is minimized. Hover a tile to select it, click it to bring
it back. When a tile lands in the tray, the tray takes the keyboard: **Left / Right**
pick a tile, **Enter** brings it back, **Backspace** closes it, **Escape** (or Down,
or SUPER+M) hands the keyboard back. **SUPER+M** hands it to the tray again later.

Hyprland has no real "minimize", so the tray is backed by a hidden special workspace
(`special:minimized`, separate from Omarchy's SUPER+S scratchpad). Maximized windows
are un-maximized for the animation and re-maximized when they come back.

## Requirements

- Omarchy 4.x with the Lua Hyprland config (`~/.config/hypr/hyprland.lua`) and the
  Omarchy shell (Quickshell). Built and tested on Omarchy 4.0.4 / Hyprland 0.56.2.
- A touchpad that reports three-finger swipes (any libinput touchpad does).

## Install

```bash
git clone https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures.git
cd omarchy-3-finger-gestures
./install.sh
```

The installer copies two Lua files into `~/.config/hypr/`, appends two `require`
lines to `hyprland.lua` (after backing it up), installs the tray plugin into
`~/.config/omarchy/plugins/`, enables it, and reloads Hyprland. Rerun it any time to
update. Nothing under `/usr/share/omarchy` is touched, so Omarchy updates leave it alone.

Uninstall with `./uninstall.sh`. It brings back any windows still in the tray first.

## Settings

Everything lives in the `opt` table at the top of `~/.config/hypr/gestures.lua`.
Save the file and Hyprland reloads by itself.

| Setting | Default | Meaning |
|---|---|---|
| `swipe_distance` | `500` | Higher = the screen follows your fingers more slowly. |
| `swipe_cancel_ratio` | `0.12` | How much of a swipe commits to the next workspace. Lower = less. |
| `swipe_min_speed_to_force` | `25` | A flick faster than this commits regardless of distance. |
| `slide_speed` | `4.5` | Glide speed after you let go. Lower = slower. `nil` leaves Omarchy's animations alone. |
| `instant_keyboard_switch` | `true` | Keep SUPER+1..0 instant even though swiping glides. |
| `persistent_workspaces` | `5` | Keep workspaces 1..N alive so a swipe visits each one and stops at N. `0` to disable. |
| `minimize` | `true` | The down/up gestures and the tray. `false` for the workspace swipe only. |
| `tray_key` | `"SUPER + M"` | Key that toggles the tray's keyboard. `nil` for none. |

Two more knobs sit at the top of `minimize.lua`: `anim_ms` (how long the shrink and
grow take) and `tray_height` (keep it equal to `trayHeight` in the tray's `Tray.qml`).

## Good to know

- **The tray takes the keyboard on purpose.** Right after a swipe down, typing goes to
  the tray until you press Escape. If you would rather it never grabbed the keyboard,
  remove the `else if (newest) root.focusMode = true` line in `Tray.qml` and use
  SUPER+M when you want it.
- **The tray reserves space** like the bar, so tiled windows re-tile when it appears
  and disappears. To float it over the bottom edge instead, set `exclusionMode:
  ExclusionMode.Ignore` in `Tray.qml`.
- **A sloppy diagonal swipe** can be read as the other axis. If down/up misfire or
  feel too eager, add `scale = 1.5` (or another value) to those two `hl.gesture`
  lines in `gestures.lua`.
- **Editing `Tray.qml`** hot-reloads, but the shell sometimes keeps the old copy
  answering. `omarchy restart shell` fixes that.
- **Something stuck in the hidden workspace?** This brings everything back to the
  current workspace:

  ```bash
  hyprctl dispatch "(function() for _, w in ipairs(hl.get_workspace_windows('special:minimized')) do hl.dispatch(hl.dsp.window.move({ window = w, workspace = '+0' })) end return hl.dsp.no_op() end)()"
  ```

## How it works

**Left and right: workspace swipe.** This one is native to Hyprland. `gestures.lua`
registers a three-finger horizontal gesture with the built-in `workspace` action, so
Hyprland itself tracks your fingers and slides the workspace with them. The settings in
the `opt` table tune how far you have to move, how little of a swipe commits, and how
fast a flick counts. Omarchy ships with the workspace slide animation turned off, so the
config turns it back on, which is what gives the glide after you let go. The SUPER+1..0
keys switch that animation off for a split second so keyboard switches stay instant.

**Down: minimize.** Hyprland has no minimize, so `minimize.lua` fakes it in three steps.
First the focused window is floated in place, with any maximize state remembered and
removed. Second it is resized to a short strip and moved to the bottom edge; Hyprland
animates position and size changes on floating windows, so that is the shrink you see.
Third, once the animation has had its time (`anim_ms`), the window is moved to a hidden
special workspace called `minimized`. Special workspaces are invisible, skipped by the
horizontal swipe, and separate from the SUPER+S scratchpad. (Simply moving a window to
another workspace only fades it, which is why the float-and-shrink detour exists.)

**The tray.** `plugins/threefinger.minimized-tray/` is a small Omarchy shell plugin
that watches Hyprland's window list (`hyprctl clients -j`, refreshed on window events).
When anything sits in the hidden workspace, it shows a bottom panel with one tile per
window and reserves space like the top bar. Hovering or arrowing to a tile writes that
window's address to `~/.local/state/omarchy/minimized-tray-selected`.

**Up: restore.** The swipe-up handler reads that state file, picks that window, and runs
the minimize steps in reverse. The window comes back as a strip at the bottom of your
current workspace, grows to its old size and position, and is then handed back to the
tiling layout or re-maximized. If nothing is selected it takes the most recently
minimized window.

**The glue.** The minimize logic is a global Lua table (`Minimize`) inside Hyprland's
own Lua runtime. Hyprland forgets that state on every config reload, so each window's
original size and tiled/maximized state is also written onto the window as a tag
(`min_...`), which survives reloads. The gestures call it directly, and the tray calls the same functions
from outside through `hyprctl dispatch`, so there is one implementation and two ways in.

## License

MIT. See `LICENSE`.
