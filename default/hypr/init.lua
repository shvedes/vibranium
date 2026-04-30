-- ############################### --
-- Load default Vibranium settings --
-- ############################### --

local home = os.getenv("HOME")

-- Base paths
local VIBRANIUM = home .. "/.local/share/vibranium/default/hypr"
local CONFIG = home .. "/.config/vibranium"
local HYPR = home .. "/.config/hypr"

local function source_file(path)
  local fn = loadfile(path)
  if fn then
    fn()
  end
end

-- ############################## --
--          Core config           --
-- ############################## --

source_file(VIBRANIUM .. "/autostart.lua")
source_file(VIBRANIUM .. "/general.lua")
source_file(VIBRANIUM .. "/look-and-feel.lua")

source_file(CONFIG .. "/current/theme/hyprland.lua")

source_file(VIBRANIUM .. "/layer-rules.lua")
source_file(VIBRANIUM .. "/window-rules.lua")

source_file(VIBRANIUM .. "/permissions.lua")
source_file(VIBRANIUM .. "/binds.lua")
source_file(VIBRANIUM .. "/input.lua")

-- ############################## --
-- Auto-load extra Lua configs    --
-- ~/.config/hypr/hyprland.conf.d --
-- ############################## --

do
  local p = io.popen('find "' .. HYPR .. '/hyprland.conf.d" -maxdepth 1 -type f,l -name "*.lua" 2>/dev/null')
  if p then
    for file in p:lines() do
      source_file(file)
    end
    p:close()
  end
end
