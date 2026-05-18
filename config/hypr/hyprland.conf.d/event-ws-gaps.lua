-- Remove / comment the line below to enable this feature.
-- Don't forget to relaod configuration.
do
  return
end

-- Not applicable in Scrolling & Monocle layouts
local layout = hl.get_config("general.layout")

if layout ~= "dwindle" and layout ~= "master" then
  return
end

-- Original configured gap values from the user's config.
-- These act as the "100%" baseline before scaling.
local baseline_in = 0
local baseline_out = 0

-- Gap scaling presets based on window count.
-- Index:
--   1 window  -> 1.00x
--   2 windows -> 0.65x
--   3 windows -> 0.40x
--   4 windows -> 0.25x
--   5+        -> 0.00x
local SCALE = { 1.0, 0.65, 0.40, 0.25, 0.00 }

-- Read a gap value from config.
--
-- Hyprland may return:
--   - a number
--   - a directional table
--
-- For directional tables, prefer:
--   top -> first array element -> fallback 0
local function read_gap(key)
  local v = hl.get_config(key)

  if type(v) == "number" then
    return v
  end

  if type(v) == "table" then
    return v.top or v[1] or 0
  end

  return 0
end

-- Capture the current configured gap values so scaling
-- always happens relative to the latest config state.
local function capture_baseline()
  baseline_in = read_gap("general.gaps_in")
  baseline_out = read_gap("general.gaps_out")
end

-- Initial baseline capture on startup.
capture_baseline()

-- Update workspace gaps dynamically based on
-- the amount of visible tiled windows currently present.
--
-- exclude_address:
--   Optionally skip one window while counting.
--
-- Needed for window.close, because the closing
-- window still exists in the workspace list at
-- the moment the event fires.
local function update_gaps(ws, exclude_address)
  if ws == nil then
    return
  end

  -- Avoid applying scaling if baseline values
  -- were not read correctly.
  if baseline_in == 0 or baseline_out == 0 then
    return
  end

  -- Count windows currently considered active
  -- for the workspace scaling calculation.
  --
  -- Grouped windows share a single tile, so the entire group
  -- must count as 1 regardless of how many members it holds.
  --
  -- w.group is a per-window Lua wrapper, so table identity cannot
  -- be used to deduplicate. Instead we key on w.group.current.address,
  -- which is the same string for every member of a given group at
  -- any point in time.
  local count = 0
  local seen_groups = {}

  for _, w in ipairs(hl.get_workspace_windows(ws)) do
    if w.address ~= exclude_address and w.floating == false then
      if w.group == nil then
        -- Not in any group: always count.
        count = count + 1
      else
        -- In a group: count once per unique current-window address.
        local group_id = w.group.current and w.group.current.address
        if group_id and not seen_groups[group_id] then
          seen_groups[group_id] = true
          count = count + 1
        end
      end
    end
  end

  -- Do not apply zero-sized layouts.
  if count == 0 then
    return
  end

  -- Clamp scale index so any amount above the
  -- table size uses the last scale preset.
  local scale = SCALE[math.min(count, #SCALE)]

  -- Scale gaps while preserving a minimum size of 1.
  -- +0.5 before floor() gives rounded integer results.
  local new_in = math.max(1, math.floor(baseline_in * scale + 0.5))
  local new_out = math.max(1, math.floor(baseline_out * scale + 0.5))

  -- Apply the newly calculated gap values globally.
  hl.config({
    general = {
      gaps_in = new_in,
      gaps_out = new_out,
    },
  })
end

-- Returns true if the active window should suppress gap updates.
--
-- Context menus on Xwayland windows behave like separate windows,
-- so the compositor adjusts gaps when hovering or clicking on them,
-- e.g. Steam. Exclude these to avoid spurious gap recalculations.
--
-- This guard is only relevant for window open/close events, where
-- the Xwayland context menu appears as a brief active window.
-- It must NOT be applied to config.reloaded or workspace.active,
-- where no such transient window is involved.
local function active_window_is_xwayland()
  local win = hl.get_active_window()
  return win == nil or win.xwayland == true
end

-- config.reloaded:
-- Re-capture baseline so manual config changes are respected
-- immediately, then re-apply scaled gaps to the active workspace.
-- Without the re-apply, Hyprland's reload resets gaps to their
-- configured defaults and they stay wrong until the next workspace
-- focus event.
hl.on("config.reloaded", function()
  capture_baseline()
  update_gaps(hl.get_active_workspace())
end)

-- window.open:
-- A new window already belongs to the workspace,
-- so no exclusion logic is necessary.
hl.on("window.open", function(win)
  if active_window_is_xwayland() then
    return
  end
  update_gaps(win.workspace)
end)

-- window.close:
-- Exclude the closing window from the count,
-- otherwise the workspace would be over-counted.
hl.on("window.close", function(win)
  if active_window_is_xwayland() then
    return
  end
  update_gaps(win.workspace, win.address)
end)

-- workspace.active:
-- Recalculate gaps whenever switching workspaces,
-- using whatever windows currently exist there.
hl.on("workspace.active", function(ws)
  update_gaps(ws)
end)
