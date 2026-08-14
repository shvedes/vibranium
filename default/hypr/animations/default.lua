-- Animation preset: default -- data only, applied via Hypr.Anim.apply (see lib/actions.lua).

Hypr.Anim.apply({
  layer_rules = {
    { animation = "slide", match = { namespace = "notifications" } },
  },

  curves = {
    { "easeOutQuint", { type = "bezier", points = { { 0.23, 1.0 }, { 0.32, 1.0 } } } },
    { "almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } } },
    { "linear", { type = "bezier", points = { { 0.0, 0.0 }, { 1.0, 1.0 } } } },
  },

  animations = {
    { leaf = "border", enabled = true, speed = 5.0, bezier = "easeOutQuint" },
    { leaf = "borderangle", enabled = true, speed = 5.0, bezier = "easeOutQuint" },

    { leaf = "fade", enabled = true, speed = 1.0, bezier = "almostLinear" },
    { leaf = "fadeIn", enabled = true, speed = 1.1, bezier = "almostLinear" },
    { leaf = "fadeOut", enabled = true, speed = 0.8, bezier = "almostLinear" },
    { leaf = "fadeDim", enabled = true, speed = 0.9, bezier = "almostLinear" },
    { leaf = "fadeSwitch", enabled = true, speed = 0.9, bezier = "almostLinear" },
    { leaf = "fadeShadow", enabled = true, speed = 0.9, bezier = "almostLinear" },

    { leaf = "layers", enabled = true, speed = 3.0, bezier = "easeOutQuint" },
    { leaf = "layersIn", enabled = true, speed = 3.0, bezier = "easeOutQuint", style = "fade" },
    { leaf = "layersOut", enabled = true, speed = 3.0, bezier = "easeOutQuint", style = "fade" },
    { leaf = "fadeLayersIn", enabled = true, speed = 3.0, bezier = "easeOutQuint" },
    { leaf = "fadeLayersOut", enabled = true, speed = 3.0, bezier = "easeOutQuint" },

    { leaf = "windows", enabled = true, speed = 3.5, bezier = "easeOutQuint" },
    { leaf = "windowsIn", enabled = true, speed = 4.5, bezier = "easeOutQuint", style = "popin 85%" },
    { leaf = "windowsOut", enabled = true, speed = 4.5, bezier = "easeOutQuint", style = "popin 90%" },
    { leaf = "windowsMove", enabled = true, speed = 3.5, bezier = "easeOutQuint" },

    { leaf = "workspaces", enabled = false , speed = 4.5, bezier = "easeOutQuint", style = "fade" },

    { leaf = "zoomFactor", enabled = true, speed = 3.0, bezier = "easeOutQuint" },
  },
})
