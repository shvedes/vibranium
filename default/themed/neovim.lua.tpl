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
        bg = "{{ background }}",
        dark_bg = "{{ background|lightness=-0.03 }}",
        darker_bg = "{{ background|lightness=-0.03 }}",
        lighter_bg = "{{ background|lightness=+0.05 }}",

        fg = "{{ foreground }}",
        dark_fg = "{{ foreground|lightness=-0.03 }}",
        light_fg = "{{ foreground|lightness=+0.03 }}",
        bright_fg = "{{ foreground|lightness=+0.05 }}",
        muted = "{{ background|lightness=+0.25 }}",

        red = "{{ color1 }}",
        yellow = "{{ color3 }}",
        orange = "{{ color11 }}",
        green = "{{ color2 }}",
        cyan = "{{ color6 }}",
        blue = "{{ color4 }}",
        purple = "{{ color5 }}",
        brown = "{{ color11|lightness=-0.05 }}",

        bright_red = "{{ color1|lightness=+0.10 }}",
        bright_yellow = "{{ color3|lightness=+0.10 }}",
        bright_green = "{{ color2|lightness=+0.10 }}",
        bright_cyan = "{{ color6|lightness=+0.10 }}",
        bright_blue = "{{ color4|lightness=+0.10 }}",
        bright_purple = "{{ color5|lightness=+0.10 }}",

        accent = "{{ accent }}",
        cursor = "{{ cursor }}",
        foreground = "{{ foreground }}",
        background = "{{ background }}",
        selection = "{{ background|lightness=+0.10 }}",
        selection_foreground = "{{ foreground|lightness=+0.20 }}",
        selection_background = "{{ background|lightness=+0.10 }}",
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
