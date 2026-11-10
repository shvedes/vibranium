-- Workspace switching animates on a laptop only: a touchpad swipe between
-- workspaces reads as stutter without it, while a desktop has no gesture for
-- the animation to smooth (a VM included). `hostnamectl chassis` answers
-- "laptop", or "convertible" for a touchscreen laptop; anything else is a
-- desktop.
local chassis = (os.getenv("CHASSIS_TYPE") or ""):lower()
local touchpad = chassis == "laptop" or chassis == "convertible"

hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1.0 }, { 0.32, 1.0 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } })
hl.curve("linear", { type = "bezier", points = { { 0.0, 0.0 }, { 1.0, 1.0 } } })

hl.animation({ leaf = "border", enabled = true, speed = 2.5, bezier = "easeOutQuint" })
hl.animation({ leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" })
hl.animation({ leaf = "layers", enabled = true, speed = 1.5, bezier = "easeOutQuint" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.5, bezier = "easeOutQuint" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.5, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 1.25, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.25, bezier = "easeOutQuint", style = "popin 85%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.25, bezier = "easeOutQuint", style = "popin 90%" })
hl.animation({ leaf = "workspaces", enabled = touchpad, speed = 2.25, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "zoomFactor", enabled = true, speed = 2, bezier = "easeOutQuint" })
