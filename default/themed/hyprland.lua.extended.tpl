ATTENTION = "rgb({{ red_strip }})"
RESIZE = "rgb({{ accent_bright_strip }})"

hl.config({
  general = {
    col = {
      active_border = "rgba({{ accent_strip|alpha=0.70 }})",
      inactive_border = "rgb({{ background_2_strip }})",
    },
  },

  decoration = {
    glow = {
      color = "rgba({{ accent_strip|alpha=0.70 }})",
      color_inactive = "rgb({{ background_2_strip }})",
    },
    shadow = {
      color = "rgba({{ accent_strip|alpha=0.70 }})",
      color_inactive = "rgb({{ background_2_strip }})",
    }
  },

  misc = {
    col = {
      splash = "rgb({{ background_0_strip }})",
    },
    background_color = "rgb({{ background_0_strip }})",
  },

  group = {
    col = {
      border_active = "rgba({{ accent_strip|alpha=0.70 }})",
      border_inactive = "rgb({{ background_3_strip }})",
      border_locked_active = {
        colors = {
          "rgba({{ yellow_strip|alpha=0.70 }})",
          "rgba({{ orange_strip|alpha=0.70 }})",
          "rgba({{ red_strip|alpha=0.70 }})",
        },
        angle = 45
      },
      border_locked_inactive = "rgba({{ background_3_strip|alpha=0.70 }})",
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
