-- Animation preset: fast -- data only, applied via Hypr.Anim.apply (see lib/actions.lua).

Hypr.Anim.apply({
  layer_rules = {
    { animation = "slide", match = { namespace = "notifications" } }
  },

  curves = {
    { "easeOutQuint", { type = "bezier", points = { { 0.23, 1.0 }, { 0.32, 1.0 } } } },
    { "almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } } },
    { "linear", { type = "bezier", points = { { 0.0, 0.0 }, { 1.0, 1.0 } } } }
  },

  animations = {
    { leaf = "border", enabled = true, speed = 2.5, bezier = "easeOutQuint" },
    { leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" },
    { leaf = "layers", enabled = true, speed = 1.5, bezier = "easeOutQuint" },
    { leaf = "fadeLayersIn", enabled = true, speed = 1.5, bezier = "easeOutQuint" },
    { leaf = "fadeLayersOut", enabled = true, speed = 1.5, bezier = "easeOutQuint" },
    { leaf = "windows", enabled = true, speed = 1.25, bezier = "easeOutQuint" },
    { leaf = "windowsIn", enabled = true, speed = 2.25, bezier = "easeOutQuint", style = "popin 85%" },
    { leaf = "windowsOut", enabled = true, speed = 2.25, bezier = "easeOutQuint", style = "popin 90%" },
    { leaf = "workspaces", enabled = true, speed = 2.25, bezier = "easeOutQuint", style = "fade" }
  },
})
