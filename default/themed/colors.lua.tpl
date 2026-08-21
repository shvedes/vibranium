-- vim:ft=lua

Vibranium = {}

Vibranium.Colors = {
  red = {
    dim = "rgb({{ red_strip|dim=0.10 }})",
    normal = "rgb({{ red_strip }})",
    bright = "rgb({{ red_strip|pop=0.10 }})",
  },

  pink = {
    dim = "rgb({{ pink_strip|dim=0.10 }})",
    normal = "rgb({{ pink_strip }})",
    bright = "rgb({{ pink_strip|pop=0.10 }})",
  },

  green = {
    dim = "rgb({{ green_strip|dim=0.10 }})",
    normal = "rgb({{ green_strip }})",
    bright = "rgb({{ green_strip|pop=0.10 }})",
  },

  yellow = {
    dim = "rgb({{ yellow_strip|dim=0.10 }})",
    normal = "rgb({{ yellow_strip }})",
    bright = "rgb({{ yellow_strip|pop=0.10 }})",
  },

  orange = {
    dim = "rgb({{ orange_strip|dim=0.10 }})",
    normal = "rgb({{ orange_strip }})",
    bright = "rgb({{ orange_strip|pop=0.10 }})",
  },

  blue = {
    dim = "rgb({{ blue_strip|dim=0.10 }})",
    normal = "rgb({{ blue_strip }})",
    bright = "rgb({{ blue_strip|pop=0.10 }})",
  },

  purple = {
    dim = "rgb({{ purple_strip|dim=0.10 }})",
    normal = "rgb({{ purple_strip }})",
    bright = "rgb({{ purple_strip|pop=0.10 }})",
  },

  cyan = {
    dim = "rgb({{ cyan_strip|dim=0.10 }})",
    normal = "rgb({{ cyan_strip }})",
    bright = "rgb({{ cyan_strip|pop=0.10 }})",
  },

  accent = {
    dim = "rgb({{ accent_strip|dim=0.10 }})",
    normal = "rgb({{ accent_strip }})",
    bright = "rgb({{ accent_strip|pop=0.10 }})",
  },
}
