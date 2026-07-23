-- Animation preset: bounce -- data only, applied via Hypr.Anim.apply (see lib/actions.lua).

Hypr.Anim.apply({
  curves = {
    { "easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } } },
    { "easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } } },
    { "linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } } },
    { "almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1 } } } },
    { "quick", { type = "bezier", points = { { 0.1, 0 }, { 0.0, 1 } } } },
    { "easy", { type = "spring", mass = 1, stiffness = 71.2633, dampening = 15.8273644 } },
    { "hobbyist", { type = "spring", mass = 1, stiffness = 40, dampening = 6 } },
    { "cat", { type = "spring", mass = 1, stiffness = 30, dampening = 6 } },
  },

  animations = {
    { leaf = "global", enabled = true, speed = 4, bezier = "default" },
    { leaf = "border", enabled = true, speed = 2, bezier = "almostLinear" },
    { leaf = "windows", enabled = true, speed = 5, spring = "cat", style = "slide" },
    { leaf = "windowsIn", enabled = true, speed = 5, spring = "cat", style = "slide" },
    { leaf = "windowsOut", enabled = true, speed = 5, spring = "cat", style = "slide bottom" },
    { leaf = "windowsMove", enabled = true, speed = 5, spring = "hobbyist" },
    { leaf = "fadeIn", enabled = true, speed = 0.865, bezier = "almostLinear" },
    { leaf = "fadeOut", enabled = true, speed = 0.73, bezier = "almostLinear" },
    { leaf = "fade", enabled = true, speed = 1.515, bezier = "quick" },
    { leaf = "layers", enabled = true, speed = 1.905, bezier = "easeOutQuint" },
    { leaf = "layersIn", enabled = true, speed = 2, bezier = "easeOutQuint", style = "slide" },
    { leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "slide" },
    { leaf = "fadeLayersIn", enabled = true, speed = 0.895, bezier = "almostLinear" },
    { leaf = "fadeLayersOut", enabled = true, speed = 0.695, bezier = "almostLinear" },
    { leaf = "workspaces", enabled = true, speed = 6, spring = "hobbyist", style = "slidevert" },
    { leaf = "workspacesIn", enabled = true, speed = 6, spring = "hobbyist", style = "slidevert" },
    { leaf = "workspacesOut", enabled = true, speed = 6, spring = "hobbyist", style = "slidevert" },
    { leaf = "zoomFactor", enabled = true, speed = 4, bezier = "quick" },
  },
})
