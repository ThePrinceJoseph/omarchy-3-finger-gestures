-- Omarchy 3 Finger Gestures
-- https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures
--
-- Three-finger touchpad gestures for Omarchy 4 (Hyprland 0.56, Lua config):
--   left / right  change workspace, gliding with your fingers
--   down          minimize the focused window into a tray at the bottom
--   up            bring the selected minimized window back (see minimize.lua)
--
-- Settings: edit ~/.config/hypr/gestures-settings.lua (the installer creates it
-- once and never overwrites it). The values below are the defaults.
-- Check for mistakes with:  hyprctl configerrors

local defaults = {
  -- Workspace swipe feel. Higher distance = the screen follows your fingers
  -- more slowly; lower cancel_ratio = less of a swipe commits to the next
  -- workspace; a quick flick above min_speed commits regardless.
  swipe_distance = 500,
  swipe_cancel_ratio = 0.12,
  swipe_min_speed_to_force = 25,
  -- Glide into place after you let go (Omarchy turns this animation off by
  -- default). Lower speed = slower slide. `false` leaves animations alone.
  slide_speed = 4.5,
  -- Keep SUPER+1..0 instant even though swiping glides.
  instant_keyboard_switch = true,
  -- Keep workspaces 1..N alive even when empty, so a swipe visits each one in
  -- order and stops at N. 0 disables.
  persistent_workspaces = 5,
  -- The minimize gestures and their tray. false = workspace swipe only.
  minimize = true,
  -- Key that hands the keyboard to the tray. false = no key.
  tray_key = "SUPER + M",
  -- How many windows the tray holds before swipe down says "full" (1..12).
  tray_max = 5,
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

if opt.slide_speed and opt.slide_speed ~= false then
  hl.animation({ leaf = "workspaces", enabled = true, speed = opt.slide_speed, bezier = "easeOutQuint", style = "slide" })
end

if opt.slide_speed and opt.instant_keyboard_switch then
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

if opt.minimize and Minimize then
  Minimize.max_windows = math.max(1, math.min(12, math.floor(tonumber(opt.tray_max) or 5)))
  hl.gesture({ fingers = 3, direction = "down", action = function() Minimize.minimize() end })
  hl.gesture({ fingers = 3, direction = "up", action = function() Minimize.restore_selected() end })
  if opt.tray_key then
    o.bind(opt.tray_key, "Minimized tray: toggle keyboard", "omarchy-shell minimized-tray focus")
  end
elseif opt.minimize then
  hl.notification.create({ text = "3 Finger Gestures: minimize.lua is not loaded (require it before gestures.lua)", timeout = 8000, icon = "warning" })
end
