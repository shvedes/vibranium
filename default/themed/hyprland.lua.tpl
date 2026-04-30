ATTENTION = "rgb({{ color9_strip }})"

hl.config({
  general = {
    col = {
      active_border = "rgb({{ accent_strip }})",
      inactive_border = "rgb({{ color8_strip }})",
    },
  },

  misc = {
    col = {
      splash = "rgb({{ background_strip }})",
    },
    background_color = "rgb({{ background_strip }})",
  },
})

-- vim:ft=lua
