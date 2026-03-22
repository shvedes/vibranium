return {
  "RRethy/base16-nvim",
  config = function()
    require("base16-colorscheme").setup({
      base00 = "{{ color0 }}",
      base01 = "{{ color1 }}",
      base02 = "{{ color2 }}",
      base03 = "{{ color3 }}",
      base04 = "{{ color4 }}",
      base05 = "{{ color5 }}",
      base06 = "{{ color6 }}",
      base07 = "{{ color7 }}",
      base08 = "{{ color8 }}",
      base09 = "{{ color9 }}",
      base0A = "{{ color10 }}",
      base0B = "{{ color11 }}",
      base0C = "{{ color12 }}",
      base0D = "{{ color13 }}",
      base0E = "{{ color14 }}",
      base0F = "{{ color15 }}",
    })
  end,
}

-- vim:ft=lua
