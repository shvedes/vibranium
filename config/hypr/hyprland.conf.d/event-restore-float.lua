-- Remove / comment the line below to enable this feature.
-- Don't forget to relaod configuration.
do return end

-- Tracks windows that originally wanted to stay floating.
-- Key: window address
-- Value: true
local wants_float = {}

-- Clear all tracking data whenever the config reloads,
-- since all runtime state becomes unreliable afterward.
hl.on("config.reloaded", function()
  wants_float = {}
end)

-- Stop tracking a window once it changes workspace.
-- Floating restoration only applies within the original workspace context.
hl.on("window.move_to_workspace", function(win)
  wants_float[win.address] = nil
end)

-- When a new window opens:
--   1. Find every other floating window on the same workspace
--   2. Tile it
--   3. Mark it so it can later be restored to floating
--
-- No grouping or parent-child relationship is tracked.
-- Every affected window is handled independently.
hl.on("window.open_early", function(new_win)
  if new_win.workspace == nil then return end

  for _, w in ipairs(hl.get_workspace_windows(new_win.workspace)) do
    -- Skip:
    --   * the newly opened window itself
    --   * already tiled windows
    if w.address == new_win.address or not w.floating then
      goto continue
    end

    -- Never auto-tile pinned windows.
    -- Pinned windows are expected to remain globally visible.
    if w.pinned then
      goto continue
    end

    -- Remember that this window used to float,
    -- then convert it into a tiled window.
    wants_float[w.address] = true
    hl.dispatch(hl.dsp.window.float({
      action = "unset",
      window = w
    }))

    ::continue::
  end
end)

-- When a window closes:
--   1. Remove it from tracking
--   2. Check whether exactly one eligible window remains
--   3. Restore floating state if that remaining window
--      originally floated before being auto-tiled
hl.on("window.close", function(closed_win)
  wants_float[closed_win.address] = nil

  if closed_win.workspace == nil then return end

  -- Build a list of surviving windows on the workspace.
  -- Pinned windows are excluded from the count, since they are
  -- never subject to auto-tiling and should not block restoration
  -- of the one remaining non-pinned window.
  local remaining = {}

  for _, w in ipairs(hl.get_workspace_windows(closed_win.workspace)) do
    -- Exclude the just-closed window and pinned windows.
    if w.address ~= closed_win.address and not w.pinned then
      table.insert(remaining, w)
    end
  end

  -- Restore only if exactly one eligible window remains.
  if #remaining ~= 1 then return end

  local sole = remaining[1]

  -- Ignore windows that were never auto-tiled.
  if not wants_float[sole.address] then return end

  -- Stop tracking before restoration.
  wants_float[sole.address] = nil

  -- Skip restoration if the window is already floating.
  -- This covers the case where the user manually re-floated it
  -- themselves before this handler ran, so we don't force an
  -- unwanted center and focus on a window the user already positioned.
  if sole.floating then return end

  -- Restore original floating behavior,
  -- center the window, and focus it for convenience.
  hl.dispatch(hl.dsp.window.float({
    action = "set",
    window = sole
  }))

  hl.dispatch(hl.dsp.window.center({ window = sole }))
  hl.dispatch(hl.dsp.focus({ window = sole }))
end)
