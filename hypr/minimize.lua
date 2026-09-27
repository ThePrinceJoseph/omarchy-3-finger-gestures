-- Omarchy 3 Finger Gestures: minimize windows with the touchpad.
-- https://github.com/ThePrinceJoseph/omarchy-3-finger-gestures
--
-- Minimize.minimize()        tucks the focused window into the hidden special
--                            workspace `special:minimized`; the dock flies a
--                            picture of it into its tile.
-- Minimize.restore(address)  brings one window back onto the current
--                            workspace; the dock flies the picture back out.
-- Minimize.restore_selected() same, for the tile selected in the dock (hover or
--                            the tray key + arrows), falling back to the most
--                            recently minimized window.
-- Minimize.restore_latest()  same, always the most recently minimized window.
-- Minimize.restore_all()     everything at once. Minimize.shutdown() for uninstall.
--
-- How the animation works: the window itself is never resized. Its picture
-- is taken (grim), then the dock plugin animates that picture between the
-- window's rectangle and its tile (`omarchy-shell minimized-tray flyOut/flyIn`)
-- while the real window is swapped out or in underneath with animations off
-- (tags `min_flying`, `min_hidden`; see the rules at the bottom).
--
-- `Minimize` is a global on purpose: the dock plugin calls it through
--   hyprctl dispatch "Minimize.restore('0x...')"
-- The gestures that call it live in gestures.lua.

Minimize = Minimize or {}
local M = Minimize

M.workspace = "special:minimized"
M.anim_ms = 320       -- ms the picture takes to fly (matches the dock plugin's flight)
M.tray_height = 40    -- logical px; gestures.lua sets it from settings and tells the dock
-- The dock writes the selected tile's address here; keep in sync with selectedPath there.
M.selected_path = os.getenv("HOME") .. "/.local/state/omarchy/minimized-tray-selected"
M.stack = M.stack or {}   -- addresses, newest last
M.saved = M.saved or {}   -- address -> geometry/state to fly back to on restore
M.busy = M.busy or {}     -- address -> true while a flight runs
M.max_windows = M.max_windows or 5  -- dock capacity, 1..12 (gestures.lua sets it from settings)
M.op = M.op or {}         -- address -> operation token; bumped on close so stale timers do nothing
M.pending = M.pending or 0          -- minimizes started but not yet landed in the dock
M.shutting_down = false             -- set by M.shutdown(); refuses new minimizes
M.thumbnails = M.thumbnails or false -- show the picture in the dock tile (gestures.lua sets it)
M.thumb_dir = os.getenv("HOME") .. "/.cache/threefinger-tray"

-- ------------------------------------------------------------------ helpers

local function vec(v)
  if type(v) ~= "table" then return 0, 0 end
  return (v.x or v[1] or 0), (v.y or v[2] or 0)
end

local function find(addr)
  return hl.get_window("address:" .. addr)
end

-- Logical (scaled, rotated) geometry of a monitor: the given one, else the
-- active one. Hyprland reports width/height in untransformed pixels, so a
-- portrait monitor (odd transform) has them swapped.
local function monitor(m)
  m = m or hl.get_active_monitor()
  local scale = (m and m.scale and m.scale > 0) and m.scale or 1
  local pw, ph = m and m.width or 1920, m and m.height or 1200
  if m and m.transform and m.transform % 2 == 1 then pw, ph = ph, pw end
  return {
    x = m and m.x or 0,
    y = m and m.y or 0,
    w = math.floor(pw / scale),
    h = math.floor(ph / scale),
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

-- Start a new operation on a window; timers compare their token to M.op[addr]
-- and bail out if anything (a close, a newer operation) has moved on since.
local function begin(addr)
  M.op[addr] = (M.op[addr] or 0) + 1
  return M.op[addr]
end

local function thumb_path(addr)
  return M.thumb_dir .. "/" .. addr:gsub("[^%w]", "") .. ".jpg"
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function rect_json(addr, x, y, w, h)
  return string.format('{"address":"%s","x":%d,"y":%d,"w":%d,"h":%d}',
    addr, math.floor(x), math.floor(y), math.floor(w), math.floor(h))
end

-- Talk to the dock plugin (omarchy-shell IPC target "minimized-tray").
local function tray(method, payload)
  if payload then
    hl.exec_cmd(string.format("omarchy-shell minimized-tray %s %q", method, payload))
  else
    hl.exec_cmd("omarchy-shell minimized-tray " .. method)
  end
end

local function tag(w, name, on)
  hl.dispatch(hl.dsp.window.tag({ window = w, tag = (on and "+" or "-") .. name }))
end

local function notify(title, body)
  hl.exec_cmd(string.format("notify-send -a '3 Finger Gestures' -t 2500 %q %q", title, body))
end

-- Hyprland throws its Lua state away on every config reload, so M.saved alone
-- is not enough: the geometry to fly back to is also written onto the window
-- as a tag (tags live in Hyprland and survive reloads):
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
    local t = tostring(raw):gsub("%*$", "")
    local fl, fs, x, y, ww, hh = t:match("^min_(%d)_(%d)_(n?%d+)_(n?%d+)_(n?%d+)_(n?%d+)$")
    if fl then
      return {
        floating = fl == "1",
        maximized = fs == "1",
        fullscreen = fs == "2",
        x = decode_num(x), y = decode_num(y), w = decode_num(ww), h = decode_num(hh),
      }, t
    end
  end
  return nil, nil
end

local function has_tag(w, name)
  local tags = w and w.tags
  if type(tags) ~= "table" then return false end
  for _, raw in ipairs(tags) do
    if tostring(raw):gsub("%*$", "") == name then return true end
  end
  return false
end

local function clear_state_tag(w)
  local _, t = state_from_tags(w)
  if t then tag(w, t, false) end
end

-- Drop the flight/hidden tags and the saved-state tag from a window.
local function clear_transient_tags(w)
  clear_state_tag(w)
  if has_tag(w, "min_flying") then tag(w, "min_flying", false) end
  if has_tag(w, "min_hidden") then tag(w, "min_hidden", false) end
end

local function forget(addr)
  os.remove(thumb_path(addr))
  M.op[addr] = (M.op[addr] or 0) + 1
  M.saved[addr] = nil
  M.busy[addr] = nil
  for i = #M.stack, 1, -1 do
    if M.stack[i] == addr then table.remove(M.stack, i) end
  end
end

-- Hyprland drops pending timers when the config reloads. A reload during a
-- flight can leave a window hidden (opacity 0) or tagged. On every load, make
-- any such window on a visible workspace plain again; windows in the dock keep
-- their state tag (restore needs it).
local function recover_stranded()
  for _, w in ipairs(hl.get_windows() or {}) do
    if not M.busy[w.address] then
      if has_tag(w, "min_flying") then tag(w, "min_flying", false) end
      if has_tag(w, "min_hidden") then tag(w, "min_hidden", false) end
      if not (w.workspace and w.workspace.name == M.workspace) and state_from_tags(w) then
        clear_state_tag(w)
      end
    end
  end
end

-- ----------------------------------------------------------------- minimize

function M.minimize(w)
  if M.shutting_down then return false end
  w = w or hl.get_active_window()
  if not w then return false end
  if w.workspace and w.workspace.name == M.workspace then return false end
  local addr = w.address
  if M.busy[addr] then return false end -- already on its way
  if M.max_windows and M.max_windows > 0 then
    local stashed = #hl.get_workspace_windows(M.workspace) + M.pending
    if stashed >= M.max_windows then
      notify("Tray is full: " .. M.max_windows .. " windows max",
        "Bring one back first, or raise Tray capacity in the 3 Finger Gestures bar widget.")
      return false
    end
  end
  M.busy[addr] = true
  M.pending = M.pending + 1
  local token = begin(addr)

  local ax, ay = vec(w.at)
  local sw, sh = vec(w.size)
  local mon = monitor()
  -- Geometry is kept relative to the monitor, so the picture can fly back
  -- onto whichever monitor is active at the time.
  local state = {
    floating = w.floating,
    maximized = (w.fullscreen == 1),
    fullscreen = (w.fullscreen == 2),
    x = ax - mon.x, y = ay - mon.y, w = sw, h = sh,
  }
  M.saved[addr] = state
  clear_state_tag(w)
  tag(w, state_tag(state), true)

  local function give_up()
    M.pending = math.max(0, M.pending - 1)
    local win = find(addr)
    if win then
      clear_transient_tags(win)
      if state.maximized and win.fullscreen ~= 1 then
        hl.dispatch(hl.dsp.window.fullscreen({ window = win, action = "set", mode = "maximized" }))
      elseif state.fullscreen and win.fullscreen ~= 2 then
        hl.dispatch(hl.dsp.window.fullscreen({ window = win, action = "set", mode = "fullscreen" }))
      end
    end
    tray("endFlight")
    forget(addr)
  end

  -- Send it to the hidden workspace with animations off: the flying picture
  -- is what the eye follows.
  -- The picture now covers the window exactly, so the real one can vanish
  -- (opacity 0, no animation), drop any maximize/fullscreen (a fullscreen
  -- window must never change workspace: Hyprland hands the state to a
  -- neighbour) and slip into the hidden workspace unseen.
  local function stash()
    local win = find(addr)
    if M.op[addr] ~= token or not win then M.pending = math.max(0, M.pending - 1) return end
    if M.shutting_down then give_up() return end
    tag(win, "min_flying", true)
    tag(win, "min_hidden", true)
    after(20, function()
      local w2 = find(addr)
      if M.op[addr] ~= token or not w2 then M.pending = math.max(0, M.pending - 1) return end
      if M.shutting_down then give_up() return end
      if w2.fullscreen == 1 then
        hl.dispatch(hl.dsp.window.fullscreen({ window = w2, action = "unset", mode = "maximized" }))
      elseif w2.fullscreen == 2 then
        hl.dispatch(hl.dsp.window.fullscreen({ window = w2, action = "unset", mode = "fullscreen" }))
      end
      after(20, function()
        local w3 = find(addr)
        if M.op[addr] ~= token or not w3 then M.pending = math.max(0, M.pending - 1) return end
        if M.shutting_down then give_up() return end
        hl.dispatch(hl.dsp.window.move({ window = w3, workspace = M.workspace, follow = false }))
        table.insert(M.stack, addr)
        M.pending = math.max(0, M.pending - 1)
        after(M.anim_ms + 200, function()
          if M.op[addr] ~= token then return end
          local w4 = find(addr)
          if w4 then tag(w4, "min_flying", false) tag(w4, "min_hidden", false) end
          M.busy[addr] = nil
        end)
      end)
    end)
  end

  local function start_flight()
    if M.op[addr] ~= token or not find(addr) then M.pending = math.max(0, M.pending - 1) return end
    if M.shutting_down then give_up() return end
    tray("flyOut", rect_json(addr, ax, ay, sw, sh))
    stash()
  end

  -- Picture: ask grim for a small image of the window as it is now, and start
  -- the flight as soon as the file exists (grim grabs its frame before it
  -- writes, so the picture is never stale). Waiting is capped at ~160 ms so
  -- a slow capture cannot stall the gesture.
  local file = thumb_path(addr)
  os.remove(file)
  hl.exec_cmd(string.format("mkdir -p %q && grim -g '%d,%d %dx%d' -s 0.3 -t jpeg -q 80 %q",
    M.thumb_dir, ax, ay, sw, sh, file))
  local tries = 0
  local function wait_for_thumb()
    tries = tries + 1
    if file_exists(file) or tries >= 8 then start_flight() else after(20, wait_for_thumb) end
  end
  after(20, wait_for_thumb)
  return true
end

-- ------------------------------------------------------------------ restore

function M.restore(addr)
  if M.busy[addr] then return false end -- a flight is already running on it
  local w = find(addr)
  if not w then forget(addr) return false end
  if not (w.workspace and w.workspace.name == M.workspace) then forget(addr) return false end
  M.busy[addr] = true
  local token = begin(addr)
  local s = state_from_tags(w) or M.saved[addr] or {}
  local mon = monitor()
  local target = current_workspace()
  -- Where the picture flies to: the saved geometry (monitor-relative), fitted
  -- onto the monitor we restore to. A tiled window lands wherever the layout
  -- puts it; the dock is told the real spot as soon as Hyprland knows it.
  local sw = math.min(s.w or math.floor(mon.w * 0.6), mon.w)
  local sh = math.min(s.h or math.floor(mon.h * 0.6), mon.h)
  local rx = s.x or math.floor((mon.w - sw) / 2)
  local ry = s.y or math.floor((mon.h - sh) / 2)
  local ax = mon.x + math.max(0, math.min(rx, mon.w - sw))
  local ay = mon.y + math.max(0, math.min(ry, mon.h - sh))
  for i = #M.stack, 1, -1 do
    if M.stack[i] == addr then table.remove(M.stack, i) end
  end

  -- The picture takes off from the tile; the real window arrives on the
  -- workspace invisible (opacity 0, no animation), takes its place in the
  -- layout, and is revealed the moment the picture lands on it.
  tray("flyIn", rect_json(addr, ax, ay, sw, sh))
  tag(w, "min_hidden", true)
  tag(w, "min_flying", true)
  after(20, function()
    local w2 = find(addr)
    if M.op[addr] ~= token or not w2 then return end
    hl.dispatch(hl.dsp.window.move({ window = w2, workspace = target, follow = true }))
    if s.floating then
      hl.dispatch(hl.dsp.window.move({ window = w2, x = ax, y = ay }))
    end
    local big = s.maximized or s.fullscreen
    -- Tell the dock where a tiled window really ended up. (A maximized one
    -- flies to the full-size rectangle it was saved with.)
    if not big then
      after(160, function()
        local w3 = find(addr)
        if M.op[addr] ~= token or not w3 then return end
        local x, y = vec(w3.at)
        local ww, hh = vec(w3.size)
        if ww > 0 and hh > 0 then tray("retarget", rect_json(addr, x, y, ww, hh)) end
      end)
    end
    -- Maximize/fullscreen again just before the reveal: it was dropped before
    -- the trip out, and Hyprland ignores the request too soon after a
    -- workspace move.
    if big then
      after(M.anim_ms - 40, function()
        local w3 = find(addr)
        if M.op[addr] ~= token or not w3 then return end
        hl.dispatch(hl.dsp.window.fullscreen({ window = w3, action = "set", mode = s.maximized and "maximized" or "fullscreen" }))
      end)
    end
    after(M.anim_ms, function()
      if M.op[addr] ~= token then return end
      local w4 = find(addr)
      if not w4 then forget(addr) return end
      tag(w4, "min_hidden", false)
      after(80, function()
        if M.op[addr] ~= token then return end
        local w5 = find(addr)
        if w5 then clear_state_tag(w5) tag(w5, "min_flying", false) end
        os.remove(thumb_path(addr))
        M.saved[addr] = nil
        M.busy[addr] = nil
      end)
    end)
  end)
  return true
end

-- Hyprland reuses window addresses, so drop what we remember about a window
-- as soon as it closes (e.g. closed from the dock while minimized).
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

-- Restore everything in the dock at once.
function M.restore_all()
  for _, w in ipairs(hl.get_workspace_windows(M.workspace)) do M.restore(w.address) end
end

-- Used by uninstall.sh: stop taking new windows, bring back everything in the
-- dock, and let anything caught mid-flight finish (its timers see the flag);
-- then make sure no window is left hidden or tagged.
function M.shutdown()
  M.shutting_down = true
  M.restore_all()
  after(M.anim_ms + 300, recover_stranded)
end

-- Runs shortly after each config load, once windows are known.
hl.timer(recover_stranded, { timeout = 300, type = "oneshot" })

-- A window in flight swaps in or out without Hyprland's own animation (the
-- dock's picture is what moves); a hidden one has already arrived but waits,
-- invisible, for the picture to land on it.
hl.window_rule({ match = { tag = "min_flying" }, no_anim = true })
hl.window_rule({ match = { tag = "min_hidden" }, opacity = "0 override", no_anim = true })

-- The dock slides up from the bottom edge when it appears and back down when
-- it goes.
hl.layer_rule({ match = { namespace = "omarchy-minimized-tray" }, animation = "slide bottom" })
