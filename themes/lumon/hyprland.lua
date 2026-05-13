ATTENTION = "rgb(e07787)"

hl.config({
  general = {
    col = {
      active_border = { colors = { "rgb(6fb8e3)" } },
      inactive_border = "rgb(335270)",
    },
  },

  decoration = {
    shadow = {
      color = "rgb(6fb8e3)",
      color_inactive = "rgba(30486077)"
    }
  },

  misc = {
    col = {
      splash = "rgb(1b2d40)",
    },
    background_color = "rgb(1b2d40)",
  },

  group = {
    col = {
      border_active = "rgba(82a8d4b3)",
      border_inactive = "rgb(335270)",
      border_locked_active = {
        colors = {
          "rgba(e9be6cb3)",
          "rgba(e9a56db3)",
          "rgba(e07787b3)",
        },
        angle = 45
      },
      border_locked_inactive = "rgba(335270b3)",
    },

    groupbar = {
      col = {
        active = "rgb(82a8d4)",
        inactive = "rgb(335270)",
        locked_active = "rgb(82a8d4)",
        locked_inactive = "rgb(335270)",
      }
    }
  }
})

-- vim:ft=lua
