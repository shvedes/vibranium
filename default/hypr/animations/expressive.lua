-- Workspace switching animates on a laptop only: a touchpad swipe between
-- workspaces reads as stutter without it, while a desktop has no gesture for
-- the animation to smooth (a VM included). `hostnamectl chassis` answers
-- "laptop", or "convertible" for a touchscreen laptop; anything else is a
-- desktop.
local chassis = (os.getenv("CHASSIS_TYPE") or ""):lower()
local touchpad = chassis == "laptop" or chassis == "convertible"

hl.curve("easeOutQuint", { type = "bezier", points = { { 0.15, 1.15 }, { 0.32, 1.0 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } })
hl.curve("linear", { type = "bezier", points = { { 0.0, 0.0 }, { 1.0, 1.0 } } })
hl.curve("WindowsIn", { type = "bezier", points = { { 0.2, 1.17 }, { 0.15, 1.0 } } })
hl.curve("screenZoom", { type = "bezier", points = { { 0.5, 1.35 }, { 0.32, 1.0 } } })
hl.curve("WindowsMove", { type = "bezier", points = { { 0.35, 1.11 }, { 0.35, 1.01 } } })

hl.animation({ leaf = "border", enabled = false, speed = 5.0, bezier = "easeOutQuint" })
hl.animation({ leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" })
hl.animation({ leaf = "border", enabled = true, speed = 0.7, bezier = "linear" })
hl.animation({ leaf = "fadeDim", enabled = true, speed = 0.7, bezier = "linear" })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 0.7, bezier = "linear" })
hl.animation({ leaf = "fadeShadow", enabled = true, speed = 0.7, bezier = "linear" })
hl.animation({ leaf = "layers", enabled = true, speed = 3.0, bezier = "easeOutQuint" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 3.0, bezier = "default" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 3.0, bezier = "default" })
hl.animation({ leaf = "workspaces", enabled = touchpad, speed = 3.0, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 3.8, bezier = "WindowsIn", style = "gnomed" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 5.0, bezier = "easeOutQuint", style = "gnomed" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 4.0, bezier = "WindowsMove", style = "slide" })
hl.animation({ leaf = "zoomFactor", enabled = true, speed = 2.5, bezier = "screenZoom" })
