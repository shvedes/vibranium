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
})

-- vim:ft=lua
