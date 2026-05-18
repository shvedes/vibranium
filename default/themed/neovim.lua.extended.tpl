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
        bg = "{{ background_1 }}",
        dark_bg = "{{ background_h }}",
        darker_bg = "{{ background_h }}",
        lighter_bg = "{{ background_1 }}",

        fg = "{{ foreground_0 }}",
        dark_fg = "{{ foreground_3 }}",
        light_fg = "{{ foreground_h }}",
        bright_fg = "{{ foreground_h }}",
        muted = "{{ foreground_4 }}",

        red = "{{ red }}",
        yellow = "{{ yellow }}",
        orange = "{{ orange }}",
        green = "{{ green }}",
        cyan = "{{ cyan }}",
        blue = "{{ blue }}",
        purple = "{{ purple }}",
        brown = "{{ orange }}",

        bright_red = "{{ red_bright }}",
        bright_yellow = "{{ yellow_bright }}",
        bright_green = "{{ green_bright }}",
        bright_cyan = "{{ cyan_bright }}",
        bright_blue = "{{ blue_bright }}",
        bright_purple = "{{ purple_bright }}",

        accent = "{{ accent }}",
        cursor = "{{ foreground_2 }}",
        foreground = "{{ foreground_0 }}",
        background = "{{ background_0 }}",
        selection = "{{ background_3 }}",
        selection_foreground = "{{ foreground_h }}",
        selection_background = "{{ black }}",
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
