return {
  {
    "bjarneo/aether.nvim",
    branch = "v3",
    name = "aether",
    priority = 1000,
    opts = {
      transparent = true,
      lualine_bold = true,
      colors = {
        bg = "#120c0e",
        dark_bg = "#0e090b",
        darker_bg = "#0e090b",
        lighter_bg = "#261a1e",

        fg = "#d9d8dc",
        dark_fg = "#b1b0b3",
        light_fg = "#ebebed",
        bright_fg = "#ebebed",
        muted = "#8a898c",

        red = "#da4453",
        yellow = "#dab044",
        orange = "#da8844",
        green = "#81b86a",
        cyan = "#eb99a1",
        blue = "#6b98c2",
        purple = "#916bc2",
        brown = "#eb99a1",

        bright_red = "#e4656c",
        bright_yellow = "#e2c174",
        bright_green = "#e4a270",
        bright_cyan = "#efa8af",
        bright_blue = "#8aaecf",
        bright_purple = "#a78ad0",

        accent = "#eb99a1",
        cursor = "#473d41",
        foreground = "#d9d8dc",
        background = "#120c0e",
        selection = "#473d41",
        selection_foreground = "#ebebed",
        selection_background = "#473d41",
      },
    },
    config = function(_, opts)
      require("aether").setup(opts)
      vim.cmd.colorscheme("aether")
    end,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "aether",
    },
  },
}

-- vim:ft=lua
