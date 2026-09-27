-- Omarchy 3 Finger Gestures: minimize windows with the touchpad.
-- https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures
--
-- Minimize.minimize()        shrinks the focused window down toward the bottom
--                            edge, then tucks it into the hidden special
--                            workspace `special:minimized`.
-- Minimize.restore(address)  brings one window back onto the current
--                            workspace, growing up from the bottom edge.
-- Minimize.restore_selected() same, for the tile selected in the tray (hover or
--                            SUPER+M + arrows), falling back to the most
--                            recently minimized window.
-- Minimize.restore_latest()  same, always the most recently minimized window.
--
-- `Minimize` is a global on purpose: the tray plugin
-- (~/.config/omarchy/plugins/threefinger.minimized-tray/) calls it through
--   hyprctl dispatch "Minimize.restore('0x...')"
-- The gestures that call it live in gestures.lua.

Minimize = Minimize or {}
local M = Minimize

M.workspace = "special:minimized"
M.anim_ms = 380       -- ms the shrink/grow takes (Omarchy's `windows` animation speed, 3.79)
M.tray_height = 40    -- logical px; keep in sync with trayHeight in the tray plugin
-- The tray writes the selected tile's address here; keep in sync with selectedPath there.
M.selected_path = os.getenv("HOME") .. "/.local/state/omarchy/minimized-tray-selected"
M.stack = M.stack or {}   -- addresses, newest last
M.saved = M.saved or {}   -- address -> geometry/state to put back on restore
M.busy = M.busy or {}     -- address -> true while a minimize/restore animation runs

local function vec(v)
  if type(v) ~= "table" then return 0, 0 end
  return (v.x or v[1] or 0), (v.y or v[2] or 0)
end

local function find(addr)
  return hl.get_window("address:" .. addr)
end

-- Logical (scaled) geometry of the active monitor.
local function monitor()
  local m = hl.get_active_monitor()
  local scale = (m and m.scale and m.scale > 0) and m.scale or 1
  return {
    x = m and m.x or 0,
    y = m and m.y or 0,
    w = m and math.floor(m.width / scale) or 1280,
    h = m and math.floor(m.height / scale) or 800,
  }
end

local function current_workspace()
  local m = hl.get_active_monitor()
  local ws = m and m.active_workspace or hl.get_active_workspace()
  return ws and tostring(ws.id) or "+0"
end

local function after(ms, fn)
  hl.timer(fn, { timeout = ms, type = "oneshot" })
end

-- Where a window of the given geometry shrinks to: a short strip at the
-- bottom edge, centred under the window.
local function tray_target(ax, sw, mon)
  local tw = math.max(160, math.floor(sw * 0.4))
  local th = M.tray_height
  local tx = math.floor(ax + sw / 2 - tw / 2)
  local ty = mon.y + mon.h - th
  return tx, ty, tw, th
end

-- Hyprland throws its Lua state away on every config reload, so M.saved alone
-- is not enough: a window minimized before a reload would come back at a
-- default size and floating. The original state is therefore also written
-- onto the window itself as a tag (tags live in Hyprland and survive reloads):
--   min_<floating 0/1>_<fullscreen 0/1/2>_<x>_<y>_<w>_<h>   (negatives as n123)
local function encode_num(n)
  n = math.floor(n or 0)
  return n < 0 and ("n" .. -n) or tostring(n)
end

local function decode_num(str)
  if str:sub(1, 1) == "n" then return -tonumber(str:sub(2)) end
  return tonumber(str)
end

local function state_tag(state)
  return "min_" .. (state.floating and 1 or 0) .. "_" .. (state.maximized and 1 or (state.fullscreen and 2 or 0))
    .. "_" .. encode_num(state.x) .. "_" .. encode_num(state.y)
    .. "_" .. encode_num(state.w) .. "_" .. encode_num(state.h)
end

-- Returns the saved state stored on the window and the exact tag it came from.
local function state_from_tags(w)
  local tags = w and w.tags
  if type(tags) ~= "table" then return nil, nil end
  for _, raw in ipairs(tags) do
    local tag = tostring(raw):gsub("%*$", "")
    local fl, fs, x, y, ww, hh = tag:match("^min_(%d)_(%d)_(n?%d+)_(n?%d+)_(n?%d+)_(n?%d+)$")
    if fl then
      return {
        floating = fl == "1",
        maximized = fs == "1",
        fullscreen = fs == "2",
        x = decode_num(x), y = decode_num(y), w = decode_num(ww), h = decode_num(hh),
      }, tag
    end
  end
  return nil, nil
end

local function clear_state_tag(w)
  local _, tag = state_from_tags(w)
  if tag then hl.dispatch(hl.dsp.window.tag({ window = w, tag = "-" .. tag })) end
end

local function forget(addr)
  M.saved[addr] = nil
  M.busy[addr] = nil
  for i = #M.stack, 1, -1 do
    if M.stack[i] == addr then table.remove(M.stack, i) end
  end
end

function M.minimize(w)
  w = w or hl.get_active_window()
  if not w then return false end
  if w.workspace and w.workspace.name == M.workspace then return false end
  local addr = w.address
  if M.busy[addr] then return false end -- already on its way
  M.busy[addr] = true

  local ax, ay = vec(w.at)
  local sw, sh = vec(w.size)
  local mon = monitor()
  -- Geometry is kept relative to the monitor, so a window can be restored on
  -- whichever monitor is active at the time.
  local state = {
    floating = w.floating,
    maximized = (w.fullscreen == 1),
    fullscreen = (w.fullscreen == 2),
    x = ax - mon.x, y = ay - mon.y, w = sw, h = sh,
  }
  M.saved[addr] = state
  clear_state_tag(w)
  hl.dispatch(hl.dsp.window.tag({ window = w, tag = "+" .. state_tag(state) }))

  -- Let go of maximize/fullscreen and float the window in place, so it can be
  -- moved and resized freely.
  if w.fullscreen == 1 then
    hl.dispatch(hl.dsp.window.fullscreen({ window = w, action = "unset", mode = "maximized" }))
  elseif w.fullscreen == 2 then
    hl.dispatch(hl.dsp.window.fullscreen({ window = w, action = "unset", mode = "fullscreen" }))
  end
  if not w.floating then
    hl.dispatch(hl.dsp.window.float({ window = w, action = "enable" }))
  end
  hl.dispatch(hl.dsp.window.resize({ window = w, x = sw, y = sh }))
  hl.dispatch(hl.dsp.window.move({ window = w, x = ax, y = ay }))

  -- Next tick: shrink toward the bottom edge, then stash it once it lands.
  after(30, function()
    local w2 = find(addr)
    if not w2 then forget(addr) return end
    local tx, ty, tw, th = tray_target(ax, sw, mon)
    -- resize first: Hyprland keeps the centre on resize, then move pins the spot
    hl.dispatch(hl.dsp.window.resize({ window = w2, x = tw, y = th }))
    hl.dispatch(hl.dsp.window.move({ window = w2, x = tx, y = ty }))
    after(M.anim_ms, function()
      local w3 = find(addr)
      if not w3 then forget(addr) return end
      hl.dispatch(hl.dsp.window.move({ window = w3, workspace = M.workspace, follow = false }))
      table.insert(M.stack, addr)
      M.busy[addr] = nil
    end)
  end)
  return true
end

function M.restore(addr)
  local w = find(addr)
  if not w then forget(addr) return false end
  if not (w.workspace and w.workspace.name == M.workspace) then forget(addr) return false end
  if M.busy[addr] then return false end
  M.busy[addr] = true
  local tagged = state_from_tags(w)
  -- Prefer what is stored on the window (survives reloads), then our table.
  -- With neither, assume a tiled window of a sensible centred size.
  local s = tagged or M.saved[addr] or { floating = false }
  if s.floating == nil then s.floating = false end
  local mon = monitor()
  local target = current_workspace()
  -- Saved geometry is monitor-relative; fit it onto the monitor we restore to.
  local sw = math.min(s.w or math.floor(mon.w * 0.6), mon.w)
  local sh = math.min(s.h or math.floor(mon.h * 0.6), mon.h)
  local rx = s.x or math.floor((mon.w - sw) / 2)
  local ry = s.y or math.floor((mon.h - sh) / 2)
  local ax = mon.x + math.max(0, math.min(rx, mon.w - sw))
  local ay = mon.y + math.max(0, math.min(ry, mon.h - sh))
  local tx, ty, tw, th = tray_target(ax, sw, mon)

  -- Start as a strip at the bottom edge on the current workspace...
  if not w.floating then
    hl.dispatch(hl.dsp.window.float({ window = w, action = "enable" }))
  end
  hl.dispatch(hl.dsp.window.resize({ window = w, x = tw, y = th }))
  hl.dispatch(hl.dsp.window.move({ window = w, x = tx, y = ty }))
  hl.dispatch(hl.dsp.window.move({ window = w, workspace = target, follow = true }))
  for i = #M.stack, 1, -1 do
    if M.stack[i] == addr then table.remove(M.stack, i) end
  end

  -- ...then grow up into place and hand it back to the layout.
  after(30, function()
    local w2 = find(addr)
    if not w2 then forget(addr) return end
    hl.dispatch(hl.dsp.window.resize({ window = w2, x = sw, y = sh }))
    hl.dispatch(hl.dsp.window.move({ window = w2, x = ax, y = ay }))
    after(M.anim_ms, function()
      local w3 = find(addr)
      if not w3 then forget(addr) return end
      clear_state_tag(w3)
      if s.floating == false then
        hl.dispatch(hl.dsp.window.float({ window = w3, action = "disable" }))
      end
      if s.maximized then
        hl.dispatch(hl.dsp.window.fullscreen({ window = w3, action = "set", mode = "maximized" }))
      elseif s.fullscreen then
        hl.dispatch(hl.dsp.window.fullscreen({ window = w3, action = "set", mode = "fullscreen" }))
      end
      M.saved[addr] = nil
      M.busy[addr] = nil
    end)
  end)
  return true
end

-- Hyprland reuses window addresses, so drop what we remember about a window
-- as soon as it closes (e.g. closed from the tray while minimized).
hl.on("window.close", function(w)
  if w and w.address then forget(w.address) end
end)

function M.restore_latest()
  local stashed = hl.get_workspace_windows(M.workspace)
  if #stashed == 0 then
    M.stack = {}
    return false
  end
  -- Newest first; skip entries whose window has closed or moved away.
  while #M.stack > 0 do
    local addr = M.stack[#M.stack]
    for _, w in ipairs(stashed) do
      if w.address == addr then return M.restore(addr) end
    end
    table.remove(M.stack)
  end
  -- Nothing left in the stack (e.g. after a config reload): take any stashed window.
  return M.restore(stashed[#stashed].address)
end

local function selected_address()
  local f = io.open(M.selected_path, "r")
  if not f then return nil end
  local addr = f:read("*l")
  f:close()
  if addr and addr:match("^0x%x+$") then return addr end
  return nil
end

function M.restore_selected()
  local addr = selected_address()
  if addr then
    for _, w in ipairs(hl.get_workspace_windows(M.workspace)) do
      if w.address == addr then return M.restore(addr) end
    end
  end
  return M.restore_latest()
end

-- The tray slides up from the bottom edge when it appears and back down when
-- it goes.
hl.layer_rule({ match = { namespace = "omarchy-minimized-tray" }, animation = "slide bottom" })
