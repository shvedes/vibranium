-- Remove / comment the line below to enable this feature.
-- Don't forget to relaod configuration.
do return end

-- Gap scaling presets based on window count.
-- Index:
--   1 window  -> 1.00x
--   2 windows -> 0.65x
--   3 windows -> 0.40x
--   4 windows -> 0.25x
--   5+        -> 0.00x
local SCALE = { 1.0, 0.65, 0.40, 0.25, 0.00 }

-- Original configured gap values from the user's config.
-- These act as the "100%" baseline before scaling, and also
-- as the values restored when the layout becomes unsupported.
-- nil means "not yet captured or could not be read", which is
-- distinct from a real, legitimate value of 0.
local baseline_in = nil
local baseline_out = nil

-- Original configured shadow enabled state.
-- Used to restore shadows to whatever the user actually had
-- configured, rather than assuming they were always on.
local baseline_shadow_enabled = nil

-- Original configured border size.
-- Used to restore border size to whatever the user actually had
-- configured, rather than assuming a fixed default.
local baseline_border_size = nil

-- Tracks whether this script currently has shadows disabled,
-- so it only calls hl.config for shadows on an actual transition,
-- not on every single update_gaps call.
local shadow_currently_disabled = false

-- Tracks whether this script currently has border size forced to 1,
-- so it only calls hl.config for border size on an actual transition.
local border_currently_forced = false

-- Tracks the last known supported/unsupported layout state,
-- so a transition into an unsupported layout can be detected
-- and defaults restored immediately, rather than leaving
-- whatever gap values were last applied.
local last_layout_supported = nil

-- Returns true only for the layouts this feature supports.
-- Checked fresh on every call rather than once at load time,
-- since the user can switch layouts at runtime.
local function layout_is_supported()
  local layout = hl.get_config("general.layout")
  return layout == "dwindle" or layout == "master"
end

-- Read a gap value from config.
--
-- Hyprland may return:
--   - a number
--   - a directional table
--
-- For directional tables, prefer:
--   top -> first array element -> nil (unresolved)
--
-- Returning nil instead of 0 when a directional table lacks both
-- "top" and index 1 keeps the same not-yet-known semantics as the
-- baseline variables, rather than silently claiming the gap is zero.
local function read_gap(key)
  local v = hl.get_config(key)

  if type(v) == "number" then
    return v
  end

  if type(v) == "table" then
    return v.top or v[1] or nil
  end

  return nil
end

-- Capture the current configured gap, shadow, and border values so
-- scaling, and later restoration, always happen relative to the
-- latest config state.
local function capture_baseline()
  baseline_in = read_gap("general.gaps_in")
  baseline_out = read_gap("general.gaps_out")
  baseline_shadow_enabled = hl.get_config("decoration.shadow.enabled")
  baseline_border_size = hl.get_config("general.border_size")
end

-- Initial baseline capture on startup.
capture_baseline()

-- Restore gaps, shadows, and border size to their originally
-- configured values. Used both when the layout becomes unsupported,
-- and available for any other case where the scaled state needs
-- to be undone.
local function restore_defaults()
  if baseline_in ~= nil and baseline_out ~= nil then
    hl.config({
      general = {
        gaps_in = baseline_in,
        gaps_out = baseline_out,
      },
    })
  end

  if shadow_currently_disabled and baseline_shadow_enabled ~= nil then
    hl.config({
      decoration = {
        shadow = {
          enabled = baseline_shadow_enabled,
        },
      },
    })
  end
  shadow_currently_disabled = false

  if border_currently_forced and baseline_border_size ~= nil then
    hl.config({
      general = {
        border_size = baseline_border_size,
      },
    })
  end
  border_currently_forced = false
end

-- Detects a transition between supported and unsupported layouts.
-- On entering an unsupported layout, restores default gaps, shadows,
-- and border size immediately instead of leaving stale scaled values
-- in place until the next window event happens to fire.
--
-- NOTE: this is only called from inside update_gaps, which itself
-- only runs from window/workspace events. There is currently no hook
-- for the layout switch itself, so the restore only takes effect on
-- the next such event, not the instant the layout changes. If a
-- config-change or layout-change event, or a timer function, exists
-- in the API, call sync_layout_state() from there directly instead.
local function sync_layout_state()
  local supported = layout_is_supported()

  if last_layout_supported == nil then
    last_layout_supported = supported
    return
  end

  if supported ~= last_layout_supported then
    if not supported then
      restore_defaults()
    end
    last_layout_supported = supported
  end
end

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

  sync_layout_state()

  -- Not applicable in Scrolling & Monocle layouts.
  if not layout_is_supported() then
    return
  end

  -- Avoid applying scaling if baseline values were not captured,
  -- i.e. genuinely unknown. A real configured value of 0 is
  -- allowed through, since the sentinel is nil rather than 0.
  if baseline_in == nil or baseline_out == nil then
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
        -- If group.current is unavailable, fall back to counting
        -- the window itself rather than dropping it silently,
        -- since an undercounted workspace can select the wrong
        -- scale tier.
        local group_id = w.group.current and w.group.current.address
        if group_id then
          if not seen_groups[group_id] then
            seen_groups[group_id] = true
            count = count + 1
          end
        else
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

  -- Scale gaps, rounding to the nearest integer.
  -- +0.5 before floor() gives rounded integer results.
  --
  -- A minimum size of 1 is only enforced when scale > 0.
  -- At the 5+ windows tier (scale == 0.00), gaps are allowed
  -- to reach true zero rather than being floored back up to 1.
  local function scale_gap(baseline)
    local scaled = math.floor(baseline * scale + 0.5)
    if scale > 0 then
      return math.max(1, scaled)
    end
    return scaled
  end

  local new_in = scale_gap(baseline_in)
  local new_out = scale_gap(baseline_out)

  -- Apply the newly calculated gap values globally.
  hl.config({
    general = {
      gaps_in = new_in,
      gaps_out = new_out,
    },
  })

  -- At zero gaps, shadows visually stick out past the edge of
  -- adjacent tiled windows with nothing between them, and a thin
  -- border helps visually separate otherwise edge-to-edge windows.
  -- Disable shadows and force border size to 1 while gaps are at
  -- zero, and restore both once gaps scale back up.
  if scale == 0 then
    if not shadow_currently_disabled then
      hl.config({
        decoration = {
          shadow = {
            enabled = false,
          },
        },
      })
      shadow_currently_disabled = true
    end

    if not border_currently_forced then
      hl.config({
        general = {
          border_size = 1,
        },
      })
      border_currently_forced = true
    end
  else
    if shadow_currently_disabled then
      if baseline_shadow_enabled ~= nil then
        hl.config({
          decoration = {
            shadow = {
              enabled = baseline_shadow_enabled,
            },
          },
        })
      end
      shadow_currently_disabled = false
    end

    if border_currently_forced then
      if baseline_border_size ~= nil then
        hl.config({
          general = {
            border_size = baseline_border_size,
          },
        })
      end
      border_currently_forced = false
    end
  end
end

-- Returns true if the given window should suppress gap updates.
--
-- Context menus on Xwayland windows behave like separate windows,
-- so the compositor adjusts gaps when hovering or clicking on them,
-- e.g. Steam. Exclude these to avoid spurious gap recalculations.
--
-- This checks the window the event is actually about, not whatever
-- window happens to be active, so a genuine Xwayland application
-- window (Java, Wine, older X11-only software) is not mistakenly
-- treated as a transient context menu.
local function window_is_xwayland(win)
  return win == nil or win.xwayland == true
end

-- config.reloaded:
-- Detect a layout transition first, using the baseline captured
-- before this reload, so restoration is not corrupted by
-- re-capturing an already-scaled value as the new baseline.
-- Only after that is baseline re-captured from the current
-- (now-restored-if-needed) config, then gaps re-applied.
hl.on("config.reloaded", function()
  sync_layout_state()
  capture_baseline()
  update_gaps(hl.get_active_workspace())
end)

-- window.open:
-- A new window already belongs to the workspace,
-- so no exclusion logic is necessary.
hl.on("window.open", function(win)
  if window_is_xwayland(win) then
    return
  end
  update_gaps(win.workspace)
end)

-- window.close:
-- Exclude the closing window from the count,
-- otherwise the workspace would be over-counted.
hl.on("window.close", function(win)
  if window_is_xwayland(win) then
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
