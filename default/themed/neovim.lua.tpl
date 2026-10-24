return {
  {
    "shvedes/prism.nvim",
    priority = 1000,
    opts = {
      palette = {
        bg = "{{ background }}", -- main editor b
        bg_dim = "{{ background|pop=0.06 }}", -- dimmed areas (statusline bg, lualine c)
        bg_float = "{{ background|pop=0.06 }}", -- floating windows (pmenu, telescope, etc.)
        bg_highlight = "{{ background|pop=0.12 }}", -- hover/selection highlights
        bg_visual = "{{ background|pop=0.12 }}", -- visual selection
        bg_search = "{{ accent }}", -- search match background

        fg = "{{ foreground }}", -- main foregorund
        fg_dim = "{{ foreground|dim=0.24 }}", -- muted text (line numbers, comments)
        fg_gutter = "{{ foreground|dim=0.24|lightness=-0.15 }}", -- signcolumn/gutter foreground

        border = "{{ background|pop=0.30 }}", -- borders

        black = "{{ black }}",
        red = "{{ red }}",
        green = "{{ green }}",
        yellow = "{{ yellow }}",
        blue = "{{ blue }}",
        magenta = "{{ purple }}",
        cyan = "{{ cyan }}",
        white = "{{ foreground|pop=0.06 }}",
        orange = "{{ orange }}",

        bright_black = "{{ foreground|dim=0.24 }}",
        bright_red = "{{ red|pop=0.10 }}",
        bright_green = "{{ green|pop=0.10 }}",
        bright_yellow = "{{ yellow|pop=0.10 }}",
        bright_blue = "{{ blue|pop=0.10 }}",
        bright_magenta = "{{ purple|pop=0.10 }}",
        bright_cyan = "{{ cyan|pop=0.10 }}",
        bright_white = "{{ foreground|pop=0.06 }}",
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
