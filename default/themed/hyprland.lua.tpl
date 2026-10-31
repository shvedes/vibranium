ATTENTION = "rgb({{ red_strip }})"
RESIZE = "rgb({{ accent_strip|pop=0.10 }})"

hl.config({
  general = {
    col = {
      active_border = "rgba({{ accent_strip|alpha=0.70 }})",
      inactive_border = "rgb({{ background_strip|pop=0.12 }})",
    },
  },

  decoration = {
    glow = {
      color = "rgba({{ accent_strip|alpha=0.70 }})",
      color_inactive = "rgb({{ background_strip|pop=0.12 }})",
    },
    shadow = {
      color = "rgba({{ accent_strip|alpha=0.70 }})",
      color_inactive = "rgb({{ background_strip|pop=0.12 }})",
    }
  },

  misc = {
    col = {
      splash = "rgb({{ background_strip }})",
    },
    background_color = "rgb({{ background_strip }})",
  },

  group = {
    col = {
      border_active = "rgba({{ accent_strip|alpha=0.70 }})",
      border_inactive = "rgb({{ background_strip|pop=0.18 }})",
      border_locked_active = {
        colors = {
          "rgba({{ yellow_strip|alpha=0.70 }})",
          "rgba({{ orange_strip|alpha=0.70 }})",
          "rgba({{ red_strip|alpha=0.70 }})",
        },
        angle = 45
      },
      border_locked_inactive = "rgba({{ background_strip|pop=0.18|alpha=0.70 }})",
    },

    groupbar = {
      col = {
        active = "rgb({{ accent_strip }})",
        inactive = "rgb({{ background_strip|pop=0.18 }})",
        locked_active = "rgb({{ accent_strip }})",
        locked_inactive = "rgb({{ background_strip|pop=0.18 }})",
      }
    }
  }
})

-- vim:ft=lua
