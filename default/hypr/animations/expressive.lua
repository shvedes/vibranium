-- Animation preset: expressive -- data only, applied via Hypr.Anim.apply (see lib/actions.lua).

Hypr.Anim.apply({
  layer_rules = {
    { animation = "slide", match = { namespace = "notifications" } },
  },

  curves = {
    { "easeOutQuint", { type = "bezier", points = { { 0.15, 1.15 }, { 0.32, 1.0 } } } },
    { "almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } } },
    { "linear", { type = "bezier", points = { { 0.0, 0.0 }, { 1.0, 1.0 } } } },
    { "WindowsIn", { type = "bezier", points = { { 0.2, 1.17 }, { 0.15, 1.0 } } } },
    { "screenZoom", { type = "bezier", points = { { 0.5, 1.35 }, { 0.32, 1.0 } } } },
    { "WindowsMove", { type = "bezier", points = { { 0.35, 1.11 }, { 0.35, 1.01 } } } },
    { "notifications", { type = "bezier", points = { { 0.2, 1.3 }, { 0.65, 1.0 } } } },
  },

  animations = {
    { leaf = "border", enabled = false, speed = 5.0, bezier = "easeOutQuint" },
    { leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" },
    { leaf = "border", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "fadeDim", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "fadeSwitch", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "fadeShadow", enabled = true, speed = 0.7, bezier = "linear" },
    { leaf = "layers", enabled = true, speed = 3.0, bezier = "notifications" },
    { leaf = "fadeLayersIn", enabled = true, speed = 3.0, bezier = "default" },
    { leaf = "fadeLayersOut", enabled = true, speed = 3.0, bezier = "default" },
    { leaf = "workspaces", enabled = false, speed = 3.0, bezier = "easeOutQuint", style = "fade" },
    { leaf = "windowsIn", enabled = true, speed = 3.8, bezier = "WindowsIn", style = "gnomed" },
    { leaf = "windowsOut", enabled = true, speed = 5.0, bezier = "easeOutQuint", style = "gnomed" },
    { leaf = "windowsMove", enabled = true, speed = 4.0, bezier = "WindowsMove", style = "slide" },
    { leaf = "zoomFactor", enabled = true, speed = 2.5, bezier = "screenZoom" },
  },
})
