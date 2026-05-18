-- Layer rules
hl.layer_rule({
  match = { namespace = "notifications" },
  animation = "slide",
})

-- Animations
-- Beziers
hl.curve("easeOutQuint", { type = "bezier", points = { { 0.15, 1.15 }, { 0.32, 1.0 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.50, 0.50 }, { 0.75, 1.0 } } })
hl.curve("linear", { type = "bezier", points = { { 0.00, 0.00 }, { 1.00, 1.0 } } })

hl.curve("WindowsIn", { type = "bezier", points = { { -0.50, 1.00 }, { 0.35, 1.00 } } })
hl.curve("WindowsOut", { type = "bezier", points = { { 1.00, 1.00 }, { 0.35, 1.00 } } })
hl.curve("screenZoom", { type = "bezier", points = { { 0.50, 1.00 }, { 0.32, 1.00 } } })
hl.curve("WindowsMove", { type = "bezier", points = { { 0.35, 1.00 }, { 0.35, 1.00 } } })
hl.curve("notifications", { type = "bezier", points = { { 0.20, 1.00 }, { 0.65, 1.00 } } })
hl.curve("Workspaces", { type = "bezier", points = { { 0.30, 1.00 }, { 0.35, 1.00 } } })

--           What          on|off  speed bezier name  opts
hl.animation({ leaf = "border", enabled = false })
hl.animation({ leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" })

hl.animation({ leaf = "border", enabled = true, speed = 0.7, bezier = "linear" })
hl.animation({ leaf = "fadeDim", enabled = true, speed = 0.7, bezier = "linear" })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 0.7, bezier = "linear" })
hl.animation({ leaf = "fadeShadow", enabled = true, speed = 0.7, bezier = "linear" })

hl.animation({ leaf = "layers", enabled = true, speed = 3.0, bezier = "notifications" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 0.8, bezier = "linear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.0, bezier = "linear" })

hl.animation({ leaf = "workspaces", enabled = true, speed = 3.0, bezier = "Workspaces", style = "slide" })

hl.animation({ leaf = "windowsIn", enabled = true, speed = 3.0, bezier = "WindowsIn", style = "slide" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 4.0, bezier = "WindowsOut", style = "slide" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 3.5, bezier = "WindowsMove", style = "slide" })

hl.animation({ leaf = "zoomFactor", enabled = true, speed = 2.5, bezier = "screenZoom" })
