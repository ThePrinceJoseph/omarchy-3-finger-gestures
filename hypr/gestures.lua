-- Omarchy 3 Finger Gestures
-- https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures
--
-- Three-finger touchpad gestures for Omarchy 4 (Hyprland 0.56, Lua config):
--   left / right  change workspace, gliding with your fingers
--   down          minimize the focused window into a tray at the bottom
--   up            bring the selected minimized window back (see minimize.lua)
--   double tap    maximize the focused window or put it back (the top bar stays
--                 visible); while the tray has the keyboard, whether the
--                 selected tile comes back maximized
--
-- Settings come from the bar widget (or `omarchy bar set threefinger.gestures
-- <key> <value>`), which writes ~/.config/hypr/gestures-settings.lua through
-- threefinger-apply. The values below are the defaults used when that file is
-- missing. Check for mistakes with:  hyprctl configerrors

local defaults = {
  swipe_distance = 500,
  swipe_cancel_ratio = 0.12,
  swipe_min_speed_to_force = 25,
  slide_speed = 4.5,            -- 0 or false: leave Omarchy's animations alone
  instant_keyboard_switch = true,
  persistent_workspaces = 5,    -- 0 disables
  minimize = true,
  tray_key = "SUPER + M",       -- false: no key
  tray_max = 5,                 -- 1..12
  tray_thumbnails = true,
  tray_reserve_space = false,
  focus_blur = false,           -- blur/dim everything but the dock while it has the keyboard
  double_tap_fullscreen = true, -- three-finger double tap maximizes (bar stays visible)
}

local opt = {}
for k, v in pairs(defaults) do opt[k] = v end
local ok, user = pcall(require, "hypr.gestures-settings")
if ok and type(user) == "table" then
  for k, v in pairs(user) do
    if defaults[k] == nil then
      hl.notification.create({ text = "3 Finger Gestures: unknown setting '" .. tostring(k) .. "' in gestures-settings.lua", timeout = 8000, icon = "warning" })
    else
      opt[k] = v
    end
  end
elseif not ok and not tostring(user):match("not found") then
  hl.notification.create({ text = "3 Finger Gestures: gestures-settings.lua has an error: " .. tostring(user), timeout = 10000, icon = "error" })
end

-- ---------------------------------------------------------------- workspaces

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

hl.config({
  gestures = {
    workspace_swipe_distance = opt.swipe_distance,
    workspace_swipe_cancel_ratio = opt.swipe_cancel_ratio,
    workspace_swipe_min_speed_to_force = opt.swipe_min_speed_to_force,
    workspace_swipe_create_new = opt.persistent_workspaces == 0,
  },
})

if opt.slide_speed and opt.slide_speed ~= false and tonumber(opt.slide_speed) and tonumber(opt.slide_speed) > 0 then
  hl.animation({ leaf = "workspaces", enabled = true, speed = opt.slide_speed, bezier = "easeOutQuint", style = "slide" })
end

if opt.slide_speed and opt.slide_speed ~= false and tonumber(opt.slide_speed) and tonumber(opt.slide_speed) > 0 and opt.instant_keyboard_switch then
  -- Switch off the slide for the duration of a keyboard switch, then put it back.
  local function instant_workspace(workspace)
    return function()
      hl.animation({ leaf = "workspaces", enabled = false })
      hl.dispatch(hl.dsp.focus({ workspace = workspace }))
      hl.timer(function()
        hl.animation({ leaf = "workspaces", enabled = true, speed = opt.slide_speed, bezier = "easeOutQuint", style = "slide" })
      end, { timeout = 50, type = "oneshot" })
    end
  end
  for workspace = 1, 10 do
    local key = "code:" .. tostring(workspace + 9) -- keycodes 10..19 are the 1..0 row
    hl.unbind("SUPER + " .. key)
    o.bind("SUPER + " .. key, "Switch to workspace " .. workspace, instant_workspace(tostring(workspace)))
  end
end

for i = 1, opt.persistent_workspaces do
  hl.workspace_rule({ workspace = tostring(i), persistent = true })
end

-- ------------------------------------------------------------------ minimize

-- `omarchy plugin remove` deletes the dock but not these files. Without the
-- dock there is nowhere to see or click minimized windows, so leave the
-- minimize gestures off and say so; uninstall.sh removes everything.
local plugin_dir = os.getenv("HOME") .. "/.config/omarchy/plugins/threefinger.gestures"
local dock_present = io.open(plugin_dir .. "/manifest.json", "r")
if dock_present then dock_present:close() end

if opt.minimize and Minimize and not dock_present then
  hl.notification.create({ text = "3 Finger Gestures: the dock plugin is missing. Reinstall it, or run uninstall.sh to remove the gestures too.", timeout = 10000, icon = "warning" })
elseif opt.minimize and Minimize then
  Minimize.max_windows = math.max(1, math.min(12, math.floor(tonumber(opt.tray_max) or 5)))
  Minimize.thumbnails = opt.tray_thumbnails and true or false
  -- The dock plugin reads its look from this file (it watches for changes).
  local f = io.open(os.getenv("HOME") .. "/.local/state/omarchy/minimized-tray-settings.json", "w")
  if f then
    -- The two-finger swipe in the dock commits by the same rule as the
    -- three-finger workspace swipe, so it gets the same numbers.
    local natural = hl.get_config("input.touchpad.natural_scroll")
    local scroll_factor = tonumber(hl.get_config("input.touchpad.scroll_factor")) or 1
    f:write(string.format('{"reserveSpace": %s, "thumbnails": %s, "focusBlur": %s, "naturalScroll": %s, '
      .. '"swipeCommit": %.2f, "swipeForce": %.2f, "scrollFactor": %.3f}\n',
      opt.tray_reserve_space and "true" or "false", Minimize.thumbnails and "true" or "false",
      opt.focus_blur and "true" or "false", (natural == true or natural == 1) and "true" or "false",
      (tonumber(opt.swipe_distance) or 500) * (tonumber(opt.swipe_cancel_ratio) or 0.12),
      tonumber(opt.swipe_min_speed_to_force) or 25, scroll_factor))
    f:close()
  end
  hl.gesture({ fingers = 3, direction = "down", action = function() Minimize.minimize() end })
  hl.gesture({ fingers = 3, direction = "up", action = function() Minimize.restore_selected() end })
  if opt.tray_key and opt.tray_key ~= "" and opt.tray_key ~= "none" then
    o.bind(opt.tray_key, "Minimized tray: toggle keyboard", "omarchy-shell minimized-tray focus")
  end
elseif opt.minimize then
  hl.notification.create({ text = "3 Finger Gestures: minimize.lua is not loaded (require it before gestures.lua)", timeout = 8000, icon = "warning" })
end

-- ---------------------------------------------------------------- double tap

-- libinput turns a three-finger tap into a middle click, so the double tap is
-- a bind on the middle button, limited to the touchpads (a mouse's or
-- trackpoint's middle button is left alone). A second tap within
-- double_tap_ms maximizes the focused window, or puts back a maximized or
-- fullscreen one (maximized keeps the top bar visible; true fullscreen would
-- cover it); a lone tap is handed on as the middle
-- click it was (paste, open in a new tab), just double_tap_ms late. While the
-- tray has the keyboard, the double tap goes to the tray instead.
local double_tap_ms = 300

-- Hyprland names input devices by lowercasing their kernel names and turning
-- spaces and commas into dashes.
local function touchpad_names()
  local names = {}
  local p = io.popen("cat /sys/class/input/event*/device/name 2>/dev/null")
  if not p then return names end
  for line in p:lines() do
    local lower = line:lower()
    if lower:match("touchpad") or lower:match("trackpad") or lower:match("clickpad") then
      table.insert(names, (lower:gsub("[ ,\n]", "-")))
    end
  end
  p:close()
  return names
end

-- One three-finger tap (a global, so it can be exercised with hyprctl dispatch).
ThreeFinger = ThreeFinger or {}
local waiting = 0  -- a lone tap is pending; its number, so a stale timer can tell
function ThreeFinger.tap()
  if waiting > 0 then
    waiting = 0
    if Minimize and Minimize.dock_focused then
      hl.dispatch(hl.dsp.event("threefinger doubletap"))
    else
      local w = hl.get_active_window()
      if w and (w.fullscreen or 0) ~= 0 then
        -- An unset has to name the mode the window is in, or it does nothing.
        hl.dispatch(hl.dsp.window.fullscreen({ window = w, action = "unset", mode = w.fullscreen == 1 and "maximized" or "fullscreen" }))
      elseif w then
        hl.dispatch(hl.dsp.window.fullscreen({ window = w, action = "set", mode = "maximized" }))
      end
    end
    return
  end
  waiting = waiting + 1
  local mine = waiting
  hl.timer(function()
    if waiting ~= mine then return end
    waiting = 0
    -- A lone tap in the tray means nothing; elsewhere it is a middle click.
    if not (Minimize and Minimize.dock_focused) then
      hl.dispatch(hl.dsp.send_shortcut({ mods = "", key = "mouse:274" }))
    end
  end, { timeout = double_tap_ms, type = "oneshot" })
end

if opt.double_tap_fullscreen then
  local pads = touchpad_names()
  if #pads > 0 then
    hl.bind("mouse:274", function() ThreeFinger.tap() end,
      { description = "Three-finger double tap: maximize", device = { inclusive = true, list = pads } })
  end
end
