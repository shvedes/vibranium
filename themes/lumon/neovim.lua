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
        bg = "#1f3347",
        dark_bg = "#141f29",
        darker_bg = "#141f29",
        lighter_bg = "#335270",

        fg = "#d6e2ee",
        dark_fg = "#a0bbd9",
        light_fg = "#c5d5e7",
        bright_fg = "#d9e4ef",
        muted = "#8fadd1",

        red = "#e07787",
        yellow = "#e9be6c",
        orange = "#e9a56d",
        green = "#88cd8b",
        cyan = "#89cdbb",
        blue = "#82a8d4",
        purple = "#8e88ce",
        brown = "#ceae88",

        bright_red = "#f2cace",
        bright_yellow = "#efd19a",
        bright_green = "#aedbae",
        bright_cyan = "#aedbce",
        bright_blue = "#a7c1e2",
        bright_purple = "#b2abdd",

        accent = "#6fb8e3",
        cursor = "#c5d5e7",
        foreground = "#d6e2ee",
        background = "#1b2d40",
        selection = "#304d69",
        selection_foreground = "#d9e4ef",
        selection_background = "#3d668f",
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
