ATTENTION = "rgb({{ red_strip }})"

hl.config({
  general = {
    col = {
      active_border = "rgba({{ accent_strip }}b3)",
      inactive_border = "rgb({{ background_3_strip }})",
    },
  },

  misc = {
    col = {
      splash = "rgb({{ background_0_strip }})",
    },
    background_color = "rgb({{ background_0_strip }})",
  },

  group = {
    col = {
      border_active = "rgba({{ accent_strip }}b3)",
      border_inactive = "rgb({{ background_3_strip }})",
      border_locked_active = {
        colors = {
          "rgba({{ yellow_strip }}b3)",
          "rgba({{ orange_strip }}b3)",
          "rgba({{ red_strip }}b3)",
        },
        angle = 45
      },
      border_locked_inactive = "rgba({{ background_3_strip }}b3)",
    },

    groupbar = {
      col = {
        active = "rgb({{ accent_strip }})",
        inactive = "rgb({{ background_3_strip }})",
        locked_active = "rgb({{ accent_strip }})",
        locked_inactive = "rgb({{ background_3_strip }})",
      }
    }
  }
})

-- vim:ft=lua
