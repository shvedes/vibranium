-- Remove / comment the line below to enable this feature.
-- Don't forget to relaod configuration.
do return end

-- Workspace -> layout mapping:
--   1 -> master
--   2 -> dwindle
--   3 -> scrolling
--
-- Any workspace not listed below falls back
-- to the default layout.

local layouts = {
  ["1"] = "master",
  ["2"] = "dwindle",
  ["3"] = "scrolling",
}

-- Layout used for every workspace that does not
-- have an explicit mapping in the table above.
local default_layout = "dwindle"

-- Trigger whenever the active workspace changes.
hl.on("workspace.active", function(ws)
  -- Pick mapped layout or fallback default.
  local layout = layouts[ws.name] or default_layout

  -- If the layout is already active.
  if hl.get_config("general.layout") == layout then
    return
  end

  -- Apply the selected layout.
  hl.config({
    general = {
      layout = layout
    }
  })
end)
