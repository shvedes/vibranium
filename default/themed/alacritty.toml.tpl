colors = {
  primary = {
    background = "{{ background }}",
    foreground = "{{ foreground }}"
  },

  cursor = {
    text = "{{ background }}",
    cursor = "{{ cursor }}"
  },

  vi_mode_cursor = {
    text = "{{ background }}",
    cursor = "{{ cursor }}"
  },

  search = {
    matches = {
      foreground = "{{ selection_foreground }}",
      background = "{{ selection_background }}"
    },

    focused_match = {
      foreground = "{{ background }}",
      background = "{{ color3|lightness=+0.10 }}"
    }
  },

  footer_bar = {
    foreground = "{{ foreground }}",
    background = "{{ background|lightness=+0.10 }}"
  },

  selection = {
    text = "{{ selection_foreground }}",
    background = "{{ selection_background }}"
  },

  normal = {
    black   = "{{ background|lightness=+0.10 }}",
    red     = "{{ color1 }}",
    green   = "{{ color2 }}",
    yellow  = "{{ color3 }}",
    blue    = "{{ color4 }}",
    magenta = "{{ color5 }}",
    cyan    = "{{ color6 }}",
    white   = "{{ color7 }}"
  },

  bright = {
    black   = "{{ background|lightness=+0.20 }}",
    red     = "{{ color1|lightness=+0.05 }}",
    green   = "{{ color2|lightness=+0.05 }}",
    yellow  = "{{ color3|lightness=+0.05 }}",
    blue    = "{{ color4|lightness=+0.05 }}",
    magenta = "{{ color5|lightness=+0.05 }}",
    cyan    = "{{ color6|lightness=+0.05 }}",
    white   = "{{ color7|lightness=+0.05 }}"
  }
}

# vim:ft=toml
