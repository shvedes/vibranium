ATTENTION = "rgb(bf2a37)"

hl.config({
  general = {
    col = {
      active_border = "rgba(aaabaeb3)",
      inactive_border = "rgb(484848)",
    },
  },

  misc = {
    col = {
      splash = "rgb(161616)",
    },
    background_color = "rgb(161616)",
  },

  group = {
    col = {
      border_active = "rgba(aaabaeb3)",
      border_inactive = "rgb(484848)",
      border_locked_active = {
        colors = {
          "rgba(f1b562b3)",
          "rgba(dd9024b3)",
          "rgba(bf2a37b3)",
        },
        angle = 45
      },
      border_locked_inactive = "rgba(484848b3)",
    },

    groupbar = {
      col = {
        active = "rgb(aaabae)",
        inactive = "rgb(484848)",
        locked_active = "rgb(aaabae)",
        locked_inactive = "rgb(484848)",
      }
    }
  }
})

-- vim:ft=lua
