-- ############################################################ --

local vibranium_install = os.getenv("VIBRANIUM")
local VIBRANIUM = vibranium_install .. "/default/hypr"

-- Module search path
package.path = package.path .. ";" .. VIBRANIUM .. "/?.lua"

-- Load Vibranium's init script first.
-- All the settings, binds, window rules and such
-- located in here. DO NOT REMOVE!
require("init")

-- ############################################################ --

-- Apply your settings below, or, better create your custom .lua files
-- in ~/.config/hypr/hyprland.conf.d/ directory to keep your setup organized.
-- After a change, if config auto reload is disabled, reload Hyprland's configuration
-- in the Utilities Menu (CTRL ALT U).
