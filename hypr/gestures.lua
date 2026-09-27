-- Omarchy 3 Finger Gestures
-- https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures
--
-- Three-finger touchpad gestures for Omarchy 4 (Hyprland 0.56, Lua config):
--   left / right  change workspace, gliding with your fingers
--   down          minimize the focused window into a tray at the bottom
--   up            bring the selected minimized window back (see minimize.lua)
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
    f:write(string.format('{"reserveSpace": %s, "thumbnails": %s, "focusBlur": %s}\n',
      opt.tray_reserve_space and "true" or "false", Minimize.thumbnails and "true" or "false",
      opt.focus_blur and "true" or "false"))
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
