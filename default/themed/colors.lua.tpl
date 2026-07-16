-- vim:ft=lua

Vibranium = {}

Vibranium.Colors = {
  red = {
    dim = "rgb({{ color1_strip|lightness=-0.15 }})",
    normal = "rgb({{ color1_strip }})",
    bright = "rgb({{ color1_strip|lightness=+0.15 }})",
  },

  pink = {
    dim = "rgb({{ color5_strip|lightness=-0.15 }})",
    normal = "rgb({{ color5_strip }})",
    bright = "rgb({{ color5_strip|lightness=+0.15 }})",
  },

  green = {
    dim = "rgb({{ color2_strip|lightness=-0.15 }})",
    normal = "rgb({{ color2_strip }})",
    bright = "rgb({{ color2_strip|lightness=+0.15 }})",
  },

  yellow = {
    dim = "rgb({{ color3_strip|lightness=-0.15 }})",
    normal = "rgb({{ color3_strip }})",
    bright = "rgb({{ color3_strip|lightness=+0.15 }})",
  },

  orange = {
    dim = "rgb({{ color11_strip|lightness=-0.15 }})",
    normal = "rgb({{ color11_strip }})",
    bright = "rgb({{ color11_strip|lightness=+0.15 }})",
  },

  blue = {
    dim = "rgb({{ color4_strip|lightness=-0.15 }})",
    normal = "rgb({{ color4_strip }})",
    bright = "rgb({{ color4_strip|lightness=+0.15 }})",
  },

  purple = {
    dim = "rgb({{ color5_strip|lightness=-0.15 }})",
    normal = "rgb({{ color5_strip }})",
    bright = "rgb({{ color5_strip|lightness=+0.15 }})",
  },

  cyan = {
    dim = "rgb({{ color6_strip|lightness=-0.15 }})",
    normal = "rgb({{ color6_strip }})",
    bright = "rgb({{ color6_strip|lightness=+0.15 }})",
  },

  accent = {
    dim = "rgb({{ accent_strip|lightness=-0.15 }})",
    normal = "rgb({{ accent_strip }})",
    bright = "rgb({{ accent_strip|lightness=+0.15 }})",
  },
}
