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
-- Minimize.close_swipe()     three fingers up while the dock is idle: prompt to
--                            close the focused window; a quick second swipe closes.
--
-- A window that was maximized or fullscreen comes back maximized (the top bar
-- stays visible) onto an empty workspace, and tiles (or floats, if it
-- floated) onto one that already has windows. Minimize.set_mode(address,
-- "full"|"tile") overrides that for one window in the dock (the dock's
-- three-finger double tap).
--
-- How the animation works: the window itself is never resized. Its picture
-- is taken (the dock captures the window's buffer), then the dock plugin animates that picture between the
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
M.inflight = M.inflight or {} -- address -> what a minimize in progress needs when the dock calls back
M.arriving = M.arriving or {} -- workspace -> restores started but not yet moved there
M.dock_focused = M.dock_focused or false -- the dock holds the keyboard (it says so on every change)

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
  local r = m and m.reserved or {}
  return {
    name = m and m.name or "",
    x = m and m.x or 0,
    y = m and m.y or 0,
    w = math.floor(pw / scale),
    h = math.floor(ph / scale),
    reserved = { top = r.top or 0, bottom = r.bottom or 0, left = r.left or 0, right = r.right or 0 },
  }
end

-- The rectangle a maximized or fullscreen window fills on a monitor.
local function big_rect(state, mon)
  if state.fullscreen then return mon.x, mon.y, mon.w, mon.h end
  local r = mon.reserved
  return mon.x + r.left, mon.y + r.top, mon.w - r.left - r.right, mon.h - r.top - r.bottom
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

-- Flight payload for the dock: the rectangle in global coordinates plus the
-- monitor it is on, so the dock can draw it on that screen's own surface.
local function rect_json(addr, x, y, w, h, mon, extra)
  return string.format('{"address":"%s","x":%d,"y":%d,"w":%d,"h":%d,"monitor":"%s","mx":%d,"my":%d%s}',
    addr, math.floor(x), math.floor(y), math.floor(w), math.floor(h),
    mon and mon.name or "", mon and mon.x or 0, mon and mon.y or 0, extra or "")
end

local function json_string(v)
  local str = tostring(v or "")
  str = str:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. str .. '"'
end

-- Talk to the dock plugin through Hyprland's own event socket: the `event`
-- dispatcher emits "custom>>threefinger <method> <payload>", which the dock
-- listens for. No process is spawned, so it arrives within a millisecond.
local function tray(method, payload)
  hl.dispatch(hl.dsp.event("threefinger " .. method .. (payload and (" " .. payload) or "")))
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

-- How a window in the dock should come back, if overridden: "full", "tile" or nil.
local function mode_from_tags(w)
  if has_tag(w, "min_mode_full") then return "full" end
  if has_tag(w, "min_mode_tile") then return "tile" end
  return nil
end

local function clear_mode_tag(w)
  if has_tag(w, "min_mode_full") then tag(w, "min_mode_full", false) end
  if has_tag(w, "min_mode_tile") then tag(w, "min_mode_tile", false) end
end

-- Drop the flight/hidden tags and the saved-state tag from a window.
local function clear_transient_tags(w)
  clear_state_tag(w)
  clear_mode_tag(w)
  if has_tag(w, "min_flying") then tag(w, "min_flying", false) end
  if has_tag(w, "min_hidden") then tag(w, "min_hidden", false) end
end

local function forget(addr)
  M.inflight[addr] = nil
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
      if not (w.workspace and w.workspace.name == M.workspace) then
        clear_mode_tag(w)
        local s = state_from_tags(w)
        if s then
          -- Put back what the interrupted trip had taken away.
          if s.floating and w.floating then
            local mon = monitor(w.monitor)
            local sw, sh = math.min(s.w or 1, mon.w), math.min(s.h or 1, mon.h)
            hl.dispatch(hl.dsp.window.resize({ window = w, x = sw, y = sh }))
            hl.dispatch(hl.dsp.window.move({ window = w, x = mon.x + math.max(0, math.min(s.x or 0, mon.w - sw)), y = mon.y + math.max(0, math.min(s.y or 0, mon.h - sh)) }))
          end
          -- Re-maximize a beat later: Hyprland ignores a fullscreen request
          -- made in the same breath as other changes to the window.
          if (s.maximized and w.fullscreen ~= 1) or (s.fullscreen and w.fullscreen ~= 2) then
            local addr, mode = w.address, s.maximized and "maximized" or "fullscreen"
            after(120, function()
              local w2 = find(addr)
              if w2 and not M.busy[addr] then
                hl.dispatch(hl.dsp.window.fullscreen({ window = w2, action = "set", mode = mode }))
              end
            end)
          end
          clear_state_tag(w)
        end
      end
    end
  end
end

-- ----------------------------------------------------------------- minimize

-- The window a swipe down takes: the focused one, as long as it really is on
-- the workspace being looked at. While the dock holds the keyboard Hyprland
-- hands focus to no window, so after a workspace switch the "active" window
-- can still be the one just minimized, or one left on another workspace. Then
-- take the window under the cursor on the workspace that is on screen, else
-- that workspace's last focused window.
local function target_window()
  local w = hl.get_active_window()
  local mon = hl.get_monitor_at_cursor() or hl.get_active_monitor()
  local ws = mon and mon.active_workspace or hl.get_active_workspace()
  if not ws then return w end
  local shown = { [ws.id] = true }
  local ok, special = pcall(hl.get_active_special_workspace)
  if ok and special and special.name ~= M.workspace then shown[special.id] = true end
  if w and w.workspace and shown[w.workspace.id] then return w end
  local wins = hl.get_workspace_windows(tostring(ws.id)) or {}
  local cx, cy = vec(hl.get_cursor_pos())
  local under
  for _, c in ipairs(wins) do
    local x, y = vec(c.at)
    local cw, ch = vec(c.size)
    if cx >= x and cx < x + cw and cy >= y and cy < y + ch then
      -- A floating window sits above the tiles, a fullscreen one above all.
      if not under or (c.fullscreen or 0) > (under.fullscreen or 0) or (c.floating and not under.floating) then under = c end
    end
  end
  return under or ws.last_window or wins[1]
end

function M.minimize(w)
  if M.shutting_down then return false end
  w = w or target_window()
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

  M.inflight[addr] = { token = token, state = state, mon = mon, ax = ax, ay = ay, sw = sw, sh = sh }

  -- Ask the dock to photograph the window (its own buffer, through the
  -- compositor) and fly the picture; the dock calls Minimize.stash() back the
  -- moment the picture is on screen, so the real window is swapped out only
  -- once there is something covering it. If the dock never answers, stash
  -- anyway after a beat so a swipe is never silently lost.
  local file = thumb_path(addr)
  os.remove(file)
  tray("flyOut", rect_json(addr, ax, ay, sw, sh, mon, string.format(',"thumbPath":"%s"', file)))
  after(300, function()
    local op = M.inflight[addr]
    if op and op.token == token then M.stash(addr) end
  end)
  return true
end

-- Second half of a minimize, called by the dock once the flying picture is
-- up (or by the safety timer above). Hides the real window (opacity 0, no
-- animation), drops any maximize/fullscreen (a fullscreen window must never
-- change workspace: Hyprland hands the state to a neighbour) and moves it to
-- the hidden workspace unseen.
function M.stash(addr)
  local op = M.inflight[addr]
  if not op then return false end
  M.inflight[addr] = nil
  local token, state, mon = op.token, op.state, op.mon
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
  local win = find(addr)
  if M.op[addr] ~= token or not win then M.pending = math.max(0, M.pending - 1) return false end
  if M.shutting_down then give_up() return false end
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
      -- A floating window that was maximized/fullscreen: remember its ordinary
      -- geometry (now that the maximize is off), not the full-screen one.
      if state.floating and (state.maximized or state.fullscreen) then
        local ox, oy = vec(w3.at)
        local ow, oh = vec(w3.size)
        state.x, state.y, state.w, state.h = ox - mon.x, oy - mon.y, ow, oh
        clear_state_tag(w3)
        tag(w3, state_tag(state), true)
      end
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
  -- Maximized again (never true fullscreen: the top bar stays visible) only
  -- onto an empty workspace, counting windows already on their way there;
  -- else it joins the layout. The dock's double tap can force either way.
  local mode = mode_from_tags(w)
  local others = #(hl.get_workspace_windows(target) or {}) + (M.arriving[target] or 0)
  local was_big = s.maximized or s.fullscreen
  local big_mode = nil
  if mode == "full" or (mode ~= "tile" and was_big and others == 0) then
    big_mode = "maximized"
  end
  M.arriving[target] = (M.arriving[target] or 0) + 1
  -- Where the picture flies to: the saved geometry (monitor-relative), fitted
  -- onto the monitor we restore to. A tiled window lands wherever the layout
  -- puts it; the dock is told the real spot as soon as Hyprland knows it.
  local sw = math.min(s.w or math.floor(mon.w * 0.6), mon.w)
  local sh = math.min(s.h or math.floor(mon.h * 0.6), mon.h)
  local rx = s.x or math.floor((mon.w - sw) / 2)
  local ry = s.y or math.floor((mon.h - sh) / 2)
  local ax = mon.x + math.max(0, math.min(rx, mon.w - sw))
  local ay = mon.y + math.max(0, math.min(ry, mon.h - sh))
  local big = big_mode ~= nil
  local fx, fy, fw, fh = ax, ay, sw, sh
  if big then fx, fy, fw, fh = big_rect({ fullscreen = big_mode == "fullscreen" }, mon) end
  for i = #M.stack, 1, -1 do
    if M.stack[i] == addr then table.remove(M.stack, i) end
  end

  -- The picture takes off from the tile; the real window arrives on the
  -- workspace invisible (opacity 0, no animation), takes its place in the
  -- layout, and is revealed the moment the picture lands on it.
  tray("flyIn", rect_json(addr, fx, fy, fw, fh, mon))
  tag(w, "min_hidden", true)
  tag(w, "min_flying", true)
  after(20, function()
    M.arriving[target] = math.max(0, (M.arriving[target] or 1) - 1)
    local w2 = find(addr)
    if M.op[addr] ~= token or not w2 then return end
    hl.dispatch(hl.dsp.window.move({ window = w2, workspace = target, follow = true }))
    if s.floating then
      hl.dispatch(hl.dsp.window.resize({ window = w2, x = sw, y = sh }))
      hl.dispatch(hl.dsp.window.move({ window = w2, x = ax, y = ay }))
    end
    -- Tell the dock where a tiled window really ended up. (A maximized one
    -- flies to the full-size rectangle it was saved with.)
    if not big then
      after(160, function()
        local w3 = find(addr)
        if M.op[addr] ~= token or not w3 then return end
        local x, y = vec(w3.at)
        local ww, hh = vec(w3.size)
        if ww > 0 and hh > 0 then tray("retarget", rect_json(addr, x, y, ww, hh, mon)) end
      end)
    end
    -- Maximize/fullscreen again just before the reveal: it was dropped before
    -- the trip out, and Hyprland ignores the request too soon after a
    -- workspace move.
    if big then
      after(M.anim_ms - 40, function()
        local w3 = find(addr)
        if M.op[addr] ~= token or not w3 then return end
        hl.dispatch(hl.dsp.window.fullscreen({ window = w3, action = "set", mode = big_mode }))
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
        if w5 then clear_state_tag(w5) clear_mode_tag(w5) tag(w5, "min_flying", false) end
        os.remove(thumb_path(addr))
        M.saved[addr] = nil
        M.busy[addr] = nil
      end)
    end)
  end)
  return true
end

-- Force how one window in the dock comes back: "full" (maximized), "tile",
-- or nil for the default (maximized only onto an empty workspace). Stored as a tag, so it
-- survives a config reload and the dock can read it from the window list.
function M.set_mode(addr, mode)
  local w = find(addr)
  if not (w and w.workspace and w.workspace.name == M.workspace) then return false end
  clear_mode_tag(w)
  if mode == "full" or mode == "tile" then tag(w, "min_mode_" .. mode, true) end
  return true
end

-- The dock reports when it takes and releases the keyboard, so a three-finger
-- double tap knows whether it is meant for the dock or for the focused window.
function M.dock_focus(on)
  M.dock_focused = on and true or false
  return M.dock_focused
end

-- ------------------------------------------------------------- undo close

-- Windows closed by the plugin (the three-finger close, the prompt, the
-- dock's ✕ / Backspace / middle click) are not closed at once: the last one
-- waits, unseen and untouched, in the hidden workspace `special:closed`, so a
-- three-finger triple tap can bring it back exactly as it was. Only the last
-- one: closing another really closes the one waiting. It also really closes
-- after M.hold_ms, because a waiting window keeps running (a video keeps
-- playing). If it asks about unsaved work then, it comes back on screen to
-- ask. The tag min_closed_<fullscreen 0/1/2> keeps all this across a reload.
M.closed_ws = "special:closed"
M.hold_ms = 30000
M.held = M.held or nil   -- { addr, token, mode } for the window waiting
local held_tokens = 0

local function closed_tag(w)
  local tags = w and w.tags
  if type(tags) ~= "table" then return nil, nil end
  for _, raw in ipairs(tags) do
    local t = tostring(raw):gsub("%*$", "")
    local mode = t:match("^min_closed_(%d)$")
    if mode then return tonumber(mode), t end
  end
  return nil, nil
end

local function clear_closed_tags(w)
  local tags = w and w.tags
  if type(tags) ~= "table" then return end
  for _, raw in ipairs(tags) do
    local t = tostring(raw):gsub("%*$", "")
    if t:match("^min_closed_%d$") then tag(w, t, false) end
  end
end

-- Close for real. If the window is still there a moment later, it is asking
-- something (unsaved work): bring it to the workspace on screen to ask.
local function really_close(addr)
  if M.held and M.held.addr == addr then M.held = nil end
  local w = find(addr)
  if not w then return end
  hl.dispatch(hl.dsp.window.close({ window = w }))
  after(1500, function()
    local w2 = find(addr)
    if w2 and w2.workspace and w2.workspace.name == M.closed_ws then
      clear_closed_tags(w2)
      hl.dispatch(hl.dsp.window.move({ window = w2, workspace = current_workspace(), follow = true }))
    end
  end)
end

local function hold(addr, mode)
  held_tokens = held_tokens + 1
  local token = held_tokens
  M.held = { addr = addr, token = token, mode = mode or 0 }
  after(M.hold_ms, function()
    if M.held and M.held.token == token then really_close(addr) end
  end)
end

function M.soft_close(addr)
  local w = find(addr)
  if not w then return false end
  if w.workspace and w.workspace.name == M.closed_ws then return false end
  if M.held and M.held.addr ~= addr then really_close(M.held.addr) end
  -- Out of the dock: it is no longer minimized.
  if w.workspace and w.workspace.name == M.workspace then
    clear_transient_tags(w)
    forget(addr)
  end
  local mode = w.fullscreen or 0
  clear_closed_tags(w)
  tag(w, "min_flying", true)
  tag(w, "min_closed_" .. mode, true)
  hold(addr, mode)
  local function move_away()
    local w2 = find(addr)
    if not w2 then return end
    hl.dispatch(hl.dsp.window.move({ window = w2, workspace = M.closed_ws, follow = false }))
    after(300, function()
      local w3 = find(addr)
      if w3 then tag(w3, "min_flying", false) end
    end)
  end
  -- A maximized or fullscreen window must drop that before it changes
  -- workspace (Hyprland hands the state to a neighbour otherwise), and
  -- Hyprland needs a moment between the two.
  if mode ~= 0 then
    hl.dispatch(hl.dsp.window.fullscreen({ window = w, action = "unset", mode = mode == 1 and "maximized" or "fullscreen" }))
    after(40, move_away)
  else
    move_away()
  end
  return true
end

-- Three-finger triple tap: bring the last closed window back onto the
-- workspace on screen, maximized again if it was (or fullscreen: maximized,
-- so the top bar stays visible).
function M.undo_close()
  local addr = M.held and M.held.addr
  local w = addr and find(addr)
  if not (w and w.workspace and w.workspace.name == M.closed_ws) then
    M.held = nil
    notify("Nothing to undo", "Only the last window closed with a gesture or from the tray comes back, for 30 seconds.")
    return false
  end
  local mode = M.held.mode
  M.held = nil
  clear_closed_tags(w)
  hl.dispatch(hl.dsp.window.move({ window = w, workspace = current_workspace(), follow = true }))
  hl.dispatch(hl.dsp.focus({ window = w }))
  if mode ~= 0 then
    after(120, function()
      local w2 = find(addr)
      if w2 then hl.dispatch(hl.dsp.window.fullscreen({ window = w2, action = "set", mode = "maximized" })) end
    end)
  end
  return true
end

-- After a reload: the waiting window is still in special:closed, but its
-- timer is gone. Keep one waiting (with a fresh timer), close any others.
local function recover_held()
  local waiting = {}
  for _, w in ipairs(hl.get_windows() or {}) do
    if w.workspace and w.workspace.name == M.closed_ws then table.insert(waiting, w) end
  end
  for i, w in ipairs(waiting) do
    if i < #waiting then really_close(w.address)
    elseif not (M.held and M.held.addr == w.address) then hold(w.address, closed_tag(w) or 0) end
  end
end
hl.timer(recover_held, { timeout = 400, type = "oneshot" })

-- Hyprland reuses window addresses, so drop what we remember about a window
-- as soon as it closes (e.g. closed from the dock while minimized).
hl.on("window.close", function(w)
  if w and w.address then
    if M.held and M.held.addr == w.address then M.held = nil end
    forget(w.address)
    if M.prompt and M.prompt.addr == w.address then M.cancel_prompt() end
  end
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
  local rounds = 0
  local function sweep()
    rounds = rounds + 1
    local left = 0
    for _, w in ipairs(hl.get_workspace_windows(M.workspace)) do
      if M.busy[w.address] then left = left + 1 else M.restore(w.address) left = left + 1 end
    end
    if left > 0 and rounds < 30 then after(150, sweep) else after(M.anim_ms + 300, recover_stranded) end
  end
  sweep()
end

-- Runs shortly after each config load, once windows are known.
hl.timer(recover_stranded, { timeout = 300, type = "oneshot" })
hl.exec_cmd("mkdir -p " .. M.thumb_dir)

-- A window in flight swaps in or out without Hyprland's own animation (the
-- dock's picture is what moves); a hidden one has already arrived but waits,
-- invisible, for the picture to land on it.
hl.window_rule({ match = { tag = "min_flying" }, no_anim = true })
hl.window_rule({ match = { tag = "min_hidden" }, opacity = "0 override", no_anim = true })

-- Scrim behind the dock while it has the keyboard: a faint tint with a light
-- blur of everything behind it. Omarchy keeps blur switched off globally, so
-- it is switched on only while the scrim is up and the user's own blur
-- settings are put back afterwards.
M.scrim_blur = { size = 1, passes = 1 }  -- light: text behind stays legible
M.prompt_blur = { size = 8, passes = 3 } -- the window about to close: unreadable
M.saved_blur = M.saved_blur or nil
M.blur_users = M.blur_users or {}     -- who needs blur on now -> { size, passes }

-- Switch blur on for whoever needs it (the strongest request wins) and put
-- the user's own settings back when nobody does.
local function set_blur(who, params)
  M.blur_users[who] = params
  local want = nil
  for _, b in pairs(M.blur_users) do
    if not want or b.size * b.passes > want.size * want.passes then want = b end
  end
  if want then
    if not M.saved_blur then
      M.saved_blur = {
        enabled = hl.get_config("decoration.blur.enabled"),
        size = hl.get_config("decoration.blur.size"),
        passes = hl.get_config("decoration.blur.passes"),
      }
    end
    hl.config({ decoration = { blur = { enabled = true, size = want.size, passes = want.passes } } })
  elseif M.saved_blur then
    local b = M.saved_blur
    M.saved_blur = nil
    hl.config({ decoration = { blur = { enabled = b.enabled and true or false, size = b.size, passes = b.passes } } })
  end
end

function M.scrim(on)
  set_blur("scrim", on and M.scrim_blur or nil)
end

-- ------------------------------------------------------------------- close

-- Three fingers up while the dock does not hold the keyboard: close the
-- focused window, after a prompt the dock draws over it (the window blurred
-- behind it). A quick double swipe up closes, whether or not the prompt is up
-- yet; so does a click on the prompt. A single swipe up while the prompt is
-- up is the wrong answer: the prompt shakes and flares (and the swipe still
-- counts as the first half of a double). Three fingers down, a workspace
-- switch or M.prompt_ms of nothing puts it away.
M.prompt_ms = 3000
M.double_swipe_ms = 800
M.prompt = nil          -- { addr, token } while the prompt is up
M.recent_up = nil       -- { addr, token } for M.double_swipe_ms after a swipe up
local prompt_tokens = 0

local function hide_prompt()
  if not M.prompt then return end
  M.prompt = nil
  tray("closePromptHide")
  set_blur("prompt", nil)
end

function M.close_window(addr)
  hide_prompt()
  M.recent_up = nil
  M.soft_close(addr)
end

function M.close_swipe()
  local w = hl.get_active_window()
  if not w or (w.workspace and w.workspace.name == M.workspace) then return false end
  local addr = w.address
  if M.recent_up and M.recent_up.addr == addr then
    M.close_window(addr)
    return true
  end
  prompt_tokens = prompt_tokens + 1
  local token = prompt_tokens
  M.recent_up = { addr = addr, token = token }
  after(M.double_swipe_ms, function()
    if M.recent_up and M.recent_up.token == token then M.recent_up = nil end
  end)
  local function expire_later()
    after(M.prompt_ms, function()
      if M.prompt and M.prompt.token == token then hide_prompt() end
    end)
  end
  -- Already asking about this window: a single swipe is not the answer.
  if M.prompt and M.prompt.addr == addr then
    M.prompt.token = token
    tray("closePromptNudge")
    expire_later()
    return true
  end
  local ax, ay = vec(w.at)
  local sw, sh = vec(w.size)
  local mon = monitor(w.monitor)
  M.prompt = { addr = addr, token = token }
  set_blur("prompt", M.prompt_blur)
  tray("closePrompt", rect_json(addr, ax, ay, sw, sh, mon, ',"title":' .. json_string(w.title ~= "" and w.title or w.class)))
  expire_later()
  return true
end

-- Three fingers down while the prompt is up cancels it (and minimizes
-- nothing). Returns true if there was a prompt to put away.
function M.cancel_prompt()
  if not M.prompt then return false end
  M.recent_up = nil
  hide_prompt()
  return true
end

-- The dock calls these when the prompt is clicked.
function M.prompt_clicked(confirm)
  if not M.prompt then return false end
  if confirm then M.close_window(M.prompt.addr) else M.cancel_prompt() end
  return true
end

hl.on("workspace.active", function() M.cancel_prompt() end)

hl.layer_rule({ match = { namespace = "omarchy-minimized-scrim" }, blur = true, animation = "fade" })
hl.layer_rule({ match = { namespace = "omarchy-close-prompt" }, blur = true, animation = "fade" })

-- The dock slides up from the bottom edge when it appears and back down when
-- it goes.
hl.layer_rule({ match = { namespace = "omarchy-minimized-tray" }, animation = "slide bottom" })
