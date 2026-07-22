return {
  {
    "shvedes/prism.nvim",
    priority = 1000,
    opts = {
      palette = {
        bg = "{{ background }}", -- main editor b
        bg_dim = "{{ background }}", -- dimmed areas (statusline bg, lualine c)
        bg_float = "{{ background|lightness=+0.03 }}", -- floating windows (pmenu, telescope, etc.)
        bg_highlight = "{{ background|lightness=+0.10 }}", -- hover/selection highlights
        bg_visual = "{{ selection_background }}", -- visual selection
        bg_search = "{{ accent }}", -- search match background

        fg = "{{ foreground }}", -- main foregorund
        fg_dim = "{{ foreground|lightness=-0.10 }}", -- muted text (line numbers, comments)
        fg_gutter = "{{ foreground|lightness=-0.10 }}", -- signcolumn/gutter foreground

        border = "{{ background|lightness=+0.30 }}", -- borders

        black = "{{ color0 }}",
        red = "{{ color1 }}",
        green = "{{ color2 }}",
        yellow = "{{ color3 }}",
        blue = "{{ color4 }}",
        magenta = "{{ color5 }}",
        cyan = "{{ color6 }}",
        white = "{{ color7 }}",
        orange = "{{ color3|lightness=-0.03 }}",

        bright_black = "{{ color0|lightness=+0.03 }}",
        bright_red = "{{ color1|lightness=+0.03 }}",
        bright_green = "{{ color2|lightness=+0.03 }}",
        bright_yellow = "{{ color3|lightness=+0.03 }}",
        bright_blue = "{{ color4|lightness=+0.03 }}",
        bright_magenta = "{{ color5|lightness+=0.03 }}",
        bright_cyan = "{{ color6|lightness=+0.03 }}",
        bright_white = "{{ color7|lightness=+0.03 }}",
      },
      transparent = true,
    },
    config = function(_, opts)
      require("prism").setup(opts)
      vim.cmd.colorscheme("prism")
    end,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "prism",
    },
  },
}

-- vim:ft=lua
