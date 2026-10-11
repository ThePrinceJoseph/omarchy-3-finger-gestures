# Omarchy 3 Finger Gestures

Touchpad gestures for [Omarchy](https://omarchy.org) 4, packaged as an Omarchy shell
plugin. Three fingers move windows and workspaces around; a tray along the bottom of the
screen holds the windows you have tucked away.

## Features

- **Workspace swipe** with three fingers. The screen follows your fingers and glides into
  place when you let go, with tunable distance, commit point, flick speed and glide.
- **Minimize** with three fingers down. The window shrinks into a tray along the bottom
  edge, as a picture of itself with its icon and title. Carry several across workspaces:
  minimize, swipe to another workspace, minimize again, swipe on, bring them back.
- **Restore** with three fingers up or two fingers up, growing out of its tile onto the
  workspace you are on. Tiled windows join the layout; floating ones land where they were.
- **A keyboard-driven tray.** Left / Right pick a tile, Enter restores, Backspace closes,
  Escape lets go. SUPER+M hands the keyboard to the tray at any time. Hover and click work too.
- **Two-finger swipe in the tray.** Sideways picks a tile, up restores it, using the same
  feel and settings as the workspace swipe.
- **Close with a prompt.** Three fingers up on a window asks first: the window blurs
  behind a prompt, and a quick double swipe (or a click on it) closes. Three fingers down
  cancels. A swipe up also dismisses any notification on screen before anything else.
- **Undo a close** with a three-finger triple tap. The last window closed by a gesture or
  from the tray comes back exactly as it was, for 30 seconds.
- **Maximize** with a three-finger double tap, keeping the top bar visible. In the tray
  it sets whether a tile comes back maximized, shown by a 󰊓 on the tile.
- **Maximized and fullscreen windows** come back maximized onto an empty workspace and
  tile onto a busy one. Nothing the plugin does covers the bar.
- **Settings in the bar.** A 󱂬 button with sliders and switches for all of it, or
  `omarchy bar set threefinger.gestures <key> <value>`. Every feature above has a switch,
  so turn off what you do not like.
- **Survives reloads.** Window state rides along on Hyprland window tags, so a config
  reload or a shell restart mid-animation leaves nothing stranded.

## Gestures

| Gesture | What happens |
|---|---|
| **Three fingers left / right** | Change workspace, gliding with your fingers. |
| **Three fingers down** | Minimize the focused window into the tray. While a close prompt is up: cancel it instead. |
| **Three fingers up** | If a notification is showing: dismiss it. Else, while the tray has the keyboard, or on an empty workspace with tiles waiting: bring the selected tile back. Else: offer to close the window on screen. |
| **Three fingers up, twice quickly** | Close the window on screen. The prompt flashes and the window goes. |
| **Three-finger double tap** | Maximize the focused window, or put a maximized or fullscreen one back. In the tray: flip whether the selected tile comes back maximized. |
| **Three-finger triple tap** | Undo the last close. |
| **Two fingers left / right** (tray has the keyboard) | Move the highlight one tile, stopping at the ends. The highlight follows your fingers. |
| **Two fingers up** (tray has the keyboard) | Bring the selected tile back. |

**The tray.** One tile per minimized window: a picture of it, its app icon and title. It
only exists while something is minimized. Hover a tile to select it and show a ✕, click
it to bring it back, middle-click to close it. When a tile lands the tray takes the
keyboard: **Left / Right** pick, **Enter** restores, **Backspace** closes, **Escape** (or
Down, SUPER+M, or a click outside the tray) hands the keyboard back. Bringing a tile back
with a swipe keeps the keyboard while tiles remain; Enter and a click hand it back. The
tray keeps the keyboard across workspace switches, so you can carry windows over. It
holds five windows by default (up to twelve): the idea is a quick way to carry a few
windows to another workspace, not a window list.

Hyprland has no real "minimize", so the tray is backed by a hidden special workspace
(`special:minimized`, separate from Omarchy's SUPER+S scratchpad). A maximized or
fullscreen window comes back maximized, with the top bar visible, onto an empty
workspace, and joins the layout onto one that already has windows. A three-finger
double tap on its tile forces either way.

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
| `double_tap_fullscreen` | `true` | Three-finger double tap maximizes the focused window or puts it back, top bar visible (in the tray: how the selected tile comes back). |
| `undo_close` | `true` | A window closed by the gesture or from the tray waits 30 s; a three-finger triple tap brings it back. `false`: it closes at once. With both tap settings off, three-finger taps are instant middle clicks again; with either on, a single tap arrives about 0.3 s late. |
| `swipe_up_close` | `true` | With the tray idle, three fingers up offers to close the window on screen. `false`: three fingers up always brings the selected tile back. |
| `swipe_up_notifications` | `true` | Three fingers up dismisses any notification on screen before doing anything else. |
| `tray_takes_keyboard` | `true` | The tray takes the keyboard when a tile lands. `false`: only the tray key hands it over. |
| `tray_two_finger` | `true` | Two-finger swipes in the tray: sideways picks a tile, up brings it back. |
| `tray_reserve_space` | `false` | `true` makes tiled windows shrink to make room for the tray. `false` floats it over the bottom edge and nothing else moves. |

The three `swipe_*` settings also drive the two-finger swipe in the tray, so one feel
covers both.

Settings live in the plugin's entry in `~/.config/omarchy/shell.json`. The generated
`~/.config/hypr/gestures-settings.lua` is rewritten from them; do not edit it by hand.
The shrink/grow duration (`anim_ms`) sits at the top of `minimize.lua`, matched to
Omarchy's window animation speed.

## Good to know

- **The dock takes the keyboard on purpose.** Right after a swipe down, typing goes to
  the dock until you press Escape or click outside it (it keeps it across workspace
  switches, so you can carry windows over), and a two-finger
  swipe anywhere picks a tile instead of scrolling. Turn on `focus_blur` to make that obvious: everything
  else on screen is lightly blurred and dimmed while the dock holds the keyboard; a workspace with no windows stays clear, since
  that is where the tiles are headed. Omarchy keeps blur off globally, so it is switched
  on only for that moment and your own blur settings are put back afterwards (strength:
  `M.scrim_blur` in `minimize.lua`). If you would rather it never grabbed the keyboard,
  turn off `tray_takes_keyboard`.
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
- **Fullscreen windows.** The dock sits on the overlay layer, so it stays visible,
  clickable and swipeable even while a fullscreen window is up (the `focus_blur` tint
  sits below fullscreen windows, so it does not show over one). The plugin itself only
  ever maximizes, which leaves the top bar visible; Omarchy's SUPER+F is still true
  fullscreen. Hyprland allows one maximized or fullscreen window per workspace: a tile
  forced maximized onto a workspace with one already takes over from it.
- **Taps and middle clicks.** libinput turns a three-finger tap into a middle click, so
  the taps are a bind on the touchpad's middle button only (a mouse or trackpoint middle
  button is untouched). Taps are counted until 0.3 s passes without another, so a single
  tap reaches the app as a middle click 0.3 s late, and a double tap maximizes 0.3 s
  after the second tap. Turn `double_tap_fullscreen` off to get instant three-finger
  middle clicks back (that turns off the double and triple tap).
- **Undoing a close.** A window closed with the gesture, the prompt or the tray's ✕ /
  Backspace / middle click waits for 30 seconds in a hidden workspace
  (`special:closed`) before it really closes, so the triple tap can bring it back as it
  was. Only the last one waits: closing another closes it for real. While it waits it
  keeps running, so sound from it keeps playing until then. If it asks about unsaved
  work when it really closes, it comes back on screen to ask. SUPER+W and an app's own
  close button close at once and cannot be undone.
- **Closing with three fingers up** only happens when the tray does not have the keyboard
  and the workspace has a window to close, so swipe down, then up, still brings a window
  straight back, and so does swiping up on an empty workspace. Otherwise, to bring one
  back, press SUPER+M first (or click its tile). The prompt blurs the window by switching
  Hyprland's blur on for a moment (Omarchy keeps it off), so slightly see-through windows
  elsewhere blur too while it is up; your blur settings are put back as it goes. Apps
  that ask before closing (unsaved work) still ask.
- **Swiping up (two or three fingers) keeps the tray's keyboard** while tiles remain, so the
  window it brought back gets the keyboard once you are done with the tray (Escape, a
  click, or the last tile).
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
