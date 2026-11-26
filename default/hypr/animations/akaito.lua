-- Workspace switching is instant in this preset; the border color fade is
-- suppressed on switch for the same reason.
local workspaceAnim = false

hl.curve("easeSoft", { type = "bezier", points = { { 0.18, 0.62 }, { 0.32, 1.0 } } })
hl.curve("easeFade", { type = "bezier", points = { { 0.28, 0.0 }, { 0.22, 1.0 } } })

hl.animation({ leaf = "windows", enabled = true, speed = 2.6, bezier = "easeSoft" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.4, bezier = "easeSoft" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.2, bezier = "easeFade" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.8, bezier = "easeSoft" })
hl.animation({ leaf = "fade", enabled = true, speed = 2.2, bezier = "easeFade" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 2.0, bezier = "easeSoft" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.8, bezier = "easeFade" })
hl.animation({ leaf = "fadeDim", enabled = true, speed = 1.8, bezier = "easeFade" })
hl.animation({ leaf = "layers", enabled = true, speed = 2.2, bezier = "easeSoft" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 2.0, bezier = "easeSoft" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.8, bezier = "easeFade" })
hl.animation({ leaf = "workspaces", enabled = workspaceAnim, speed = 2.4, bezier = "easeSoft" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 2.2, bezier = "easeSoft" })
local borderAnim = { leaf = "border", enabled = true, speed = 2.8, bezier = "easeSoft" }
hl.animation(borderAnim)
if not workspaceAnim then
  Hypr.Helpers.SkipBorderFade(borderAnim)
end
hl.animation({ leaf = "borderangle", enabled = true, speed = 3.0, bezier = "easeSoft" })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 1.4, bezier = "easeFade" })
