-- Workspace switching is instant in this preset; the border color fade is
-- suppressed on switch for the same reason.
local workspaceAnim = false

hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1.0 }, { 0.32, 1.0 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } })
hl.curve("linear", { type = "bezier", points = { { 0.0, 0.0 }, { 1.0, 1.0 } } })

local borderAnim = { leaf = "border", enabled = true, speed = 5.0, bezier = "easeOutQuint" }
hl.animation(borderAnim)
hl.animation({ leaf = "borderangle", enabled = true, speed = 5.0, bezier = "easeOutQuint" })

hl.animation({ leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.1, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 0.8, bezier = "almostLinear" })
hl.animation({ leaf = "fadeDim", enabled = true, speed = 0.9, bezier = "almostLinear" })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 0.9, bezier = "almostLinear" })
hl.animation({ leaf = "fadeShadow", enabled = true, speed = 0.9, bezier = "almostLinear" })

hl.animation({ leaf = "layers", enabled = true, speed = 3.0, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 3.0, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 3.0, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 3.0, bezier = "easeOutQuint" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 3.0, bezier = "easeOutQuint" })

hl.animation({ leaf = "windows", enabled = true, speed = 3.5, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.5, bezier = "easeOutQuint", style = "popin 85%" })
hl.animation({ leaf = "windowsOut", enabled = false, speed = 4.5, bezier = "easeOutQuint", style = "popin 70%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 3.5, bezier = "easeOutQuint" })

hl.animation({ leaf = "workspaces", enabled = workspaceAnim, speed = 4.5, bezier = "easeOutQuint", style = "fade" })
if not workspaceAnim then
  Hypr.Helpers.SkipBorderFade(borderAnim)
end

hl.animation({ leaf = "zoomFactor", enabled = true, speed = 3.0, bezier = "easeOutQuint" })
