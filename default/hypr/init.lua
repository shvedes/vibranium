-- ############################### --
-- Load default Vibranium settings --
-- ############################### --

local home = os.getenv("HOME")

-- Base paths
local VIBRANIUM = home .. "/.local/share/vibranium/default/hypr"
local CONFIG = home .. "/.config/vibranium"
local HYPR = home .. "/.config/hypr"

local function exists_file(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function exists_dir(path)
  local f = io.open(path .. "/.", "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- Runs a shell command, collects its output lines into a table, and sorts
-- them before returning. `find`'s output order is filesystem-dependent, not
-- alphabetical, so without this two files in the same directory could load
-- in a different order on a different machine (or after an unrelated file
-- got added/removed) even though nothing about THIS load changed. Since
-- lib/*.lua files build on each other via shared globals (Vibranium,
-- Hypr.Helpers), that's a silent-breakage risk, not just cosmetic -- hence
-- sorting, rather than trusting directory order.
local function popen_lines_sorted(cmd)
  local lines = {}
  local p = io.popen(cmd)
  if not p then
    return lines
  end

  for line in p:lines() do
    table.insert(lines, line)
  end
  p:close()

  table.sort(lines)
  return lines
end

local function source(path)
  -- If path contains a glob/wildcard, expand it
  if path:find("[*?%[%]]") then
    local dir = path:match("^(.*)/[^/]+$") or "."
    local pattern = path:match("([^/]+)$")

    for _, file in ipairs(popen_lines_sorted('find "' .. dir .. '" -maxdepth 1 -type f 2>/dev/null')) do
      if pattern == "*" or file:match(pattern:gsub("%.", "%%."):gsub("%*", ".*"):gsub("%?", ".")) then
        local fn = loadfile(file)
        if fn then
          fn()
        end
      end
    end
  else
    if exists_dir(path) then
      for _, file in ipairs(popen_lines_sorted('find "' .. path .. '" -maxdepth 1 -type f -name "*.lua" 2>/dev/null')) do
        local fn = loadfile(file)
        if fn then
          fn()
        end
      end
    elseif exists_file(path) then
      local fn = loadfile(path)
      if fn then
        fn()
      end
    end
  end
end

-- ############################## --
--          Core config           --
-- ############################## --

-- Explicit, not a glob: actions.lua bootstraps the Vibranium/Hypr namespace
-- tables and must run before hyprland.lua, which adds functions onto
-- Hypr.Helpers rather than creating it. A glob here would leave that order
-- up to the filesystem again -- see git history for why that's a problem.

source(VIBRANIUM .. "/lib/actions.lua")
source(VIBRANIUM .. "/lib/hyprland.lua")

source(VIBRANIUM .. "/autostart.lua")
source(VIBRANIUM .. "/general.lua")
source(VIBRANIUM .. "/look-and-feel.lua")

source(CONFIG .. "/current/theme/colors.lua")
source(CONFIG .. "/current/theme/hyprland.lua")

source(VIBRANIUM .. "/window-rules.lua")
source(VIBRANIUM .. "/permissions.lua")
source(VIBRANIUM .. "/binds.lua")
source(VIBRANIUM .. "/input.lua")
source(VIBRANIUM .. "/events.lua")

-- ############################## --
-- Auto-load extra Lua configs    --
-- ~/.config/hypr/hyprland.conf.d --
-- ############################## --

for _, file in ipairs(popen_lines_sorted('find "' .. HYPR .. '/hyprland.conf.d" -type f,l -name "*.lua" 2>/dev/null')) do
  source(file)
end
