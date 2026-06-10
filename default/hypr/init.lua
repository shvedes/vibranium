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

local function source(path)
  -- If path contains a glob/wildcard, expand it
  if path:find("[*?%[%]]") then
    local dir = path:match("^(.*)/[^/]+$") or "."
    local pattern = path:match("([^/]+)$")

    local p = io.popen('find "' .. dir .. '" -maxdepth 1 -type f 2>/dev/null')
    if p then
      for file in p:lines() do
        if pattern == "*" or file:match(pattern:gsub("%.", "%%."):gsub("%*", ".*"):gsub("%?", ".")) then
          local fn = loadfile(file)
          if fn then fn() end
        end
      end
      p:close()
    end
  else
    if exists_dir(path) then
      local p = io.popen('find "' .. path .. '" -maxdepth 1 -type f -name "*.lua" 2>/dev/null')
      if p then
        for file in p:lines() do
          local fn = loadfile(file)
          if fn then fn() end
        end
        p:close()
      end
    elseif exists_file(path) then
      local fn = loadfile(path)
      if fn then fn() end
    end
  end
end

-- ############################## --
--          Core config           --
-- ############################## --

source(VIBRANIUM .. "/lib/*.lua")

source(VIBRANIUM .. "/autostart.lua")
source(VIBRANIUM .. "/general.lua")
source(VIBRANIUM .. "/look-and-feel.lua")

source(CONFIG .. "/current/theme/vb-lib-theme.lua")
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

do
  local p = io.popen('find "' .. HYPR .. '/hyprland.conf.d" -type f,l -name "*.lua" 2>/dev/null')
  if p then
    for file in p:lines() do
      source(file)
    end
    p:close()
  end
end
