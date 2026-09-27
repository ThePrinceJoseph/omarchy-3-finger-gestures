-- Omarchy 3 Finger Gestures: your settings.
-- This file is yours: the installer creates it once and never overwrites it.
-- Delete a line to go back to the default for that setting. Save, and Hyprland
-- reloads by itself; check for mistakes with:  hyprctl configerrors

return {
  -- Workspace swipe feel. Higher distance = the screen follows your fingers
  -- more slowly; lower cancel_ratio = less of a swipe commits to the next
  -- workspace; a quick flick above min_speed commits regardless.
  swipe_distance = 500,
  swipe_cancel_ratio = 0.12,
  swipe_min_speed_to_force = 25,

  -- Glide into place after you let go. Lower speed = slower slide.
  -- Set to false to leave Omarchy's animations alone.
  slide_speed = 4.5,

  -- Keep SUPER+1..0 instant even though swiping glides.
  instant_keyboard_switch = true,

  -- Keep workspaces 1..N alive even when empty, so a swipe visits each one in
  -- order and stops at N instead of skipping empty ones. 0 disables.
  persistent_workspaces = 5,

  -- The minimize gestures and their tray. false = workspace swipe only.
  minimize = true,

  -- Key that hands the keyboard to the tray (Left/Right pick a tile, Enter
  -- restores, Escape lets go). false = no key.
  tray_key = "SUPER + M",
}
