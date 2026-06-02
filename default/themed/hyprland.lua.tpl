ATTENTION = "rgb({{ color1_strip }})"
RESIZE = "rgb({{ accent_strip|lightness=+0.20 }})"

hl.config({
  general = {
    col = {
      active_border = "rgb({{ accent_strip|lightness=+0.05 }})",
      inactive_border = "rgb({{ background_strip|lightness=+0.10 }})",
    },
  },

  misc = {
    col = {
      splash = "rgb({{ background_strip }})",
    },
    background_color = "rgb({{ background_strip }})",
  },

  group = {
    col = {
      border_active = "rgba({{ accent_strip }}b3)",
      border_inactive = "rgb({{ background_strip|lightness=+0.10 }})",
      border_locked_active = {
        colors = {
          "rgba({{ color3_strip }}b3)",
          "rgba({{ color11_strip }}b3)",
          "rgba({{ color1_strip }}b3)",
        },
        angle = 45
      },
      border_locked_inactive = "rgba({{ background_strip|lightness=+0.20 }}b3)",
    },

    groupbar = {
      col = {
        active = "rgb({{ accent_strip }})",
        inactive = "rgb({{ background_strip|lightness=+0.20 }})",
        locked_active = "rgb({{ accent_strip }})",
        locked_inactive = "rgb({{ background_strip|lightness=+0.20 }})"
      }
    }
  }
})

-- vim:ft=lua
