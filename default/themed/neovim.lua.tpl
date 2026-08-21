return {
  {
    "shvedes/prism.nvim",
    priority = 1000,
    opts = {
      palette = {
        bg = "{{ background_0 }}", -- main editor b
        bg_dim = "{{ background_1 }}", -- dimmed areas (statusline bg, lualine c)
        bg_float = "{{ background_1 }}", -- floating windows (pmenu, telescope, etc.)
        bg_highlight = "{{ background_2 }}", -- hover/selection highlights
        bg_visual = "{{ background_2 }}", -- visual selection
        bg_search = "{{ accent }}", -- search match background

        fg = "{{ foreground_0 }}", -- main foregorund
        fg_dim = "{{ foreground_4 }}", -- muted text (line numbers, comments)
        fg_gutter = "{{ foreground_4|lightness=-0.15 }}", -- signcolumn/gutter foreground

        border = "{{ background_5 }}", -- borders

        black = "{{ black }}",
        red = "{{ red }}",
        green = "{{ green }}",
        yellow = "{{ yellow }}",
        blue = "{{ blue }}",
        magenta = "{{ purple }}",
        cyan = "{{ cyan }}",
        white = "{{ foreground_h }}",
        orange = "{{ orange }}",

        bright_black = "{{ foreground_4 }}",
        bright_red = "{{ red|pop=0.10 }}",
        bright_green = "{{ green|pop=0.10 }}",
        bright_yellow = "{{ yellow|pop=0.10 }}",
        bright_blue = "{{ blue|pop=0.10 }}",
        bright_magenta = "{{ purple|pop=0.10 }}",
        bright_cyan = "{{ cyan|pop=0.10 }}",
        bright_white = "{{ foreground_h }}",
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
