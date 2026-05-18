-- Fallback.
-- These will be overwritten by a theme
ATTENTION = "rgba(255,0,0,1.0)"
ACTIVEBORDERCOLOR = "rgb(255,255,255)"
INACTIVEBORDERCOLOR = "rgba(255,255,255,0.5)"

hl.config({
  general = {
    gaps_in = 5,
    gaps_out = 7,
    border_size = 2,

    col = {
      active_border = ACTIVEBORDERCOLOR,
      inactive_border = INACTIVEBORDERCOLOR,
    },
  },

  decoration = {
    rounding = 0,

    dim_inactive = true,
    dim_strength = 0.1,
    dim_special = 0.4,
    dim_around = 0.4,
    dim_modal = true,

    border_part_of_window = false,

    blur = {
      enabled = false,
      xray = true,

      passes = 3,
      size = 3,
    },

    shadow = {
      enabled = true,
      color = "rgba(17171770)",
      render_power = 0,
      range = 5,
    },
  },

  group = {
    groupbar = {
      height = 16,
      font_size = 12,
      indicator_gap = 0,
      indicator_height = 8,
      render_titles = false,
      font_weight_active = "bold",
      font_weight_inactive = "light"
    }
  },

  animations = {
    enabled = os.getenv("CHASSIS_TYPE") ~= "vm",
  },

  misc = {
    animate_manual_resizes = true,
  },
})
