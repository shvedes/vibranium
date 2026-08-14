-- Animation preset: akaito -- data only, applied via Hypr.Anim.apply (see lib/actions.lua).

Hypr.Anim.apply({
  curves = {
    { "easeSoft", { type = "bezier", points = { { 0.18, 0.62 }, { 0.32, 1.0 } } } },
    { "easeFade", { type = "bezier", points = { { 0.28, 0.0 }, { 0.22, 1.0 } } } },
  },

  animations = {
    { leaf = "windows", enabled = true, speed = 2.6, bezier = "easeSoft" },
    { leaf = "windowsIn", enabled = true, speed = 2.4, bezier = "easeSoft" },
    { leaf = "windowsOut", enabled = true, speed = 2.2, bezier = "easeFade" },
    { leaf = "windowsMove", enabled = true, speed = 2.8, bezier = "easeSoft" },
    { leaf = "fade", enabled = true, speed = 2.2, bezier = "easeFade" },
    { leaf = "fadeIn", enabled = true, speed = 2.0, bezier = "easeSoft" },
    { leaf = "fadeOut", enabled = true, speed = 1.8, bezier = "easeFade" },
    { leaf = "fadeDim", enabled = true, speed = 1.8, bezier = "easeFade" },
    { leaf = "layers", enabled = true, speed = 2.2, bezier = "easeSoft" },
    { leaf = "layersIn", enabled = true, speed = 2.0, bezier = "easeSoft" },
    { leaf = "layersOut", enabled = true, speed = 1.8, bezier = "easeFade" },
    { leaf = "workspaces", enabled = false, speed = 2.4, bezier = "easeSoft" },
    { leaf = "specialWorkspace", enabled = true, speed = 2.2, bezier = "easeSoft" },
    { leaf = "border", enabled = true, speed = 2.8, bezier = "easeSoft" },
    { leaf = "borderangle", enabled = true, speed = 3.0, bezier = "easeSoft" },
    { leaf = "fadeSwitch", enabled = true, speed = 1.4, bezier = "easeFade" },
  },
})
