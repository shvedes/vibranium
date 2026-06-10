-- The colors defined here are overridden by the currently active theme.
-- If a theme's hyprland.lua does not define specific color values,
-- the values from this file are used as a fallback.

-- For better coverage, add 'hyprland.lua' to the $vb_force_template_files
-- array in ~/.config/vibranium/settings.advanced.

hl.config({
  general = {
    gaps_in = 5,
    gaps_out = 7,
    border_size = 2,

    col = {
      active_border = "rgb(ffffff)",
      inactive_border = "rgba(ffffff80)", -- 50% transparent
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
      enabled = os.getenv("CHASSIS_TYPE") ~= "vm",
      color = "rgba(17171770)",
      render_power = 0,
      range = 5,
    },
  },

  group = {
    col = {
      border_active = "rgb(ffffff)",
      border_inactive = "rgba(ffffff80)",
      border_locked_active = {
        colors = {
          "rgba(ffd900b3)",
          "rgba(ff9900b3)",
          "rgba(ff0000b3)",
        },
        angle = 45
      },
      border_locked_inactive = {
        colors = {
          "rgba(ffd90059)",
          "rgba(ff990059)",
          "rgba(ff000059)",
        },
        angle = 45
      }
    },

    groupbar = {
      col = {
        active = "rgb(ffffff)",
        inactive = "rgba(ffffff80)",
        locked_active = "rgba(ffffffbf)",
        locked_inactive = "rgba(ffffff66)",
      },

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
    col = {
      splash = "rgb(000000)",
    },
    animate_manual_resizes = true,
    background_color = "rgb(000000)"
  },
})
