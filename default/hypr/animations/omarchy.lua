-- Animation preset: omarchy -- data only, applied via Hypr.Anim.apply (see lib/actions.lua).

Hypr.Anim.apply({
  curves = {
    { "easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } } },
    { "easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } } },
    { "linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } } },
    { "almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } } },
    { "quick", { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } } }
  },

  animations = {
    { leaf = "global", enabled = true, speed = 10, bezier = "default" },
    { leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" },
    { leaf = "windows", enabled = true, speed = 4.79, bezier = "easeOutQuint" },
    { leaf = "windowsIn", enabled = true, speed = 4.1, bezier = "easeOutQuint", style = "popin 87%" },
    { leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" },
    { leaf = "fadeIn", enabled = true, speed = 1.73, bezier = "almostLinear" },
    { leaf = "fadeOut", enabled = true, speed = 1.46, bezier = "almostLinear" },
    { leaf = "fade", enabled = true, speed = 3.03, bezier = "quick" },
    { leaf = "layers", enabled = true, speed = 3.81, bezier = "easeOutQuint" },
    { leaf = "layersIn", enabled = true, speed = 4.0, bezier = "easeOutQuint", style = "fade" },
    { leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "fade" },
    { leaf = "fadeLayersIn", enabled = true, speed = 1.79, bezier = "almostLinear" },
    { leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" },
    { leaf = "workspaces", enabled = true, speed = 3.0, bezier = "easeOutQuint", style = "fade" }
  },
})
