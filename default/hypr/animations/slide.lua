-- Animation preset: slide -- data only, applied via Hypr.Anim.apply (see lib/actions.lua).

Hypr.Anim.apply({
  layer_rules = {
    { animation = "slide", match = { namespace = "notifications" } },
  },

  curves = {
    { "easeOutQuint", { type = "bezier", points = { { 0.15, 1.15 }, { 0.32, 1.0 } } } },
    { "almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } } },
    { "linear", { type = "bezier", points = { { 0.0, 0.0 }, { 1.0, 1.0 } } } },
    { "WindowsIn", { type = "bezier", points = { { -0.5, 1.0 }, { 0.35, 1.0 } } } },
    { "WindowsOut", { type = "bezier", points = { { 1.0, 1.0 }, { 0.35, 1.0 } } } },
    { "screenZoom", { type = "bezier", points = { { 0.5, 1.0 }, { 0.32, 1.0 } } } },
    { "WindowsMove", { type = "bezier", points = { { 0.35, 1.0 }, { 0.35, 1.0 } } } },
    { "notifications", { type = "bezier", points = { { 0.2, 1.0 }, { 0.65, 1.0 } } } },
    { "Workspaces", { type = "bezier", points = { { 0.3, 1.0 }, { 0.35, 1.0 } } } },
  },

  animations = {
    { leaf = "border", enabled = false },
    { leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" },
    { leaf = "border", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "fadeDim", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "fadeSwitch", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "fadeShadow", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "layers", enabled = true, speed = 3.0, bezier = "notifications" },
    { leaf = "fadeLayersIn", enabled = true, speed = 0.8, bezier = "linear" },
    { leaf = "fadeLayersOut", enabled = true, speed = 1.0, bezier = "linear" },
    { leaf = "workspaces", enabled = true, speed = 3.0, bezier = "Workspaces", style = "slide" },
    { leaf = "windowsIn", enabled = true, speed = 3.0, bezier = "WindowsIn", style = "slide" },
    { leaf = "windowsOut", enabled = true, speed = 4.0, bezier = "WindowsOut", style = "slide" },
    { leaf = "windowsMove", enabled = true, speed = 3.5, bezier = "WindowsMove", style = "slide" },
    { leaf = "zoomFactor", enabled = true, speed = 2.5, bezier = "screenZoom" },
  },
})
