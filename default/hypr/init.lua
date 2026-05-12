-- ############################### --
-- Load default Vibranium settings --
-- ############################### --

local home = os.getenv("HOME")

-- Base paths
local VIBRANIUM = home .. "/.local/share/vibranium/default/hypr"
local CONFIG = home .. "/.config/vibranium"
local HYPR = home .. "/.config/hypr"

local function source(path)
  -- If path contains a glob/wildcard, expand it
  if path:find("[*?%[%]]") then
    local p = io.popen('find "$(dirname \'' ..
      path .. '\')" -maxdepth 1 -type f,l -name "' .. path:match("[^/]+$") .. '" 2>/dev/null | sort')
    if p then
      for file in p:lines() do
        local fn = loadfile(file)
        if fn then fn() end
      end
      p:close()
    end
  else
    -- Check if it's a directory
    local attr = io.popen('[ -d "' .. path .. '" ] && echo dir || [ -f "' .. path .. '" ] && echo file || echo missing')
    local kind = attr and attr:read("*l") or "missing"
    if attr then attr:close() end

    if kind == "dir" then
      local p = io.popen('find "' .. path .. '" -maxdepth 1 -type f,l -name "*.lua" 2>/dev/null | sort')
      if p then
        for file in p:lines() do
          local fn = loadfile(file)
          if fn then fn() end
        end
        p:close()
      end
    elseif kind == "file" then
      local fn = loadfile(path)
      if fn then fn() end
    end
    -- silently skip if missing (matches original behaviour)
  end
end

-- ############################## --
--          Core config           --
-- ############################## --

source(VIBRANIUM .. "/autostart.lua")
source(VIBRANIUM .. "/general.lua")
source(VIBRANIUM .. "/look-and-feel.lua")

source(CONFIG .. "/current/theme/hyprland.lua")

source(VIBRANIUM .. "/layer-rules.lua")
source(VIBRANIUM .. "/window-rules.lua")
source(VIBRANIUM .. "/window-rules/*.lua")

source(VIBRANIUM .. "/permissions.lua")
source(VIBRANIUM .. "/binds.lua")
source(VIBRANIUM .. "/input.lua")
source(VIBRANIUM .. "/events.lua")

-- ############################## --
-- Auto-load extra Lua configs    --
-- ~/.config/hypr/hyprland.conf.d --
-- ############################## --

do
  local p = io.popen('find "' .. HYPR .. '/hyprland.conf.d" -maxdepth 1 -type f,l -name "*.lua" 2>/dev/null')
  if p then
    for file in p:lines() do
      source(file)
    end
    p:close()
  end
end
