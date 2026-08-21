colors = {
  primary = {
    background = "{{ background_0 }}",
    foreground = "{{ foreground_0 }}",
    dim_foreground = "{{ foreground_4 }}",
    bright_foreground = "{{ foreground_h }}"
  },

  cursor = {
    text = "{{ background_0 }}",
    cursor = "{{ foreground_2 }}"
  },

  vi_mode_cursor = {
    text = "{{ foreground_h }}",
    cursor = "{{ blue }}"
  },

  search = {
    matches = {
      background = "{{ background_2 }}",
      foreground = "{{ foreground_0 }}"
    }
  },

  hints = {
    start = {
      background = "{{ background_2 }}",
      foreground = "{{ foreground_0 }}"
    },
    end = {
      background = "{{ background_2 }}",
      foreground = "{{ foreground_0 }}"
    }
  },

  line_indicator = {
    background = "{{ background_2 }}",
    foreground = "{{ foreground_0 }}"
  },

  footer_bar = {
    background = "{{ background_2 }}",
    foreground = "{{ foreground_0 }}"
  },

  selection = {
    background = "{{ background_3 }}",
    foreground = "{{ foreground_h }}"
  },

  normal = {
    black   = "{{ background_4 }}",
    red     = "{{ red }}",
    green   = "{{ green }}",
    yellow  = "{{ yellow }}",
    blue    = "{{ blue }}",
    magenta = "{{ purple }}",
    cyan    = "{{ cyan }}",
    white   = "{{ white }}"
  },

  bright = {
    black   = "{{ background_5 }}",
    red     = "{{ red|pop=0.10 }}",
    green   = "{{ green|pop=0.10 }}",
    yellow  = "{{ yellow|pop=0.10 }}",
    blue    = "{{ blue|pop=0.10 }}",
    magenta = "{{ purple|pop=0.10 }}",
    cyan    = "{{ cyan|pop=0.10 }}",
    white   = "{{ white|pop=0.10 }}"
  },

  dim = {
    black   = "{{ background_3 }}",
    red     = "{{ red|dim=0.10 }}",
    green   = "{{ green|dim=0.10 }}",
    yellow  = "{{ yellow|dim=0.10 }}",
    blue    = "{{ blue|dim=0.10 }}",
    magenta = "{{ purple|dim=0.10 }}",
    cyan    = "{{ cyan|dim=0.10 }}",
    white   = "{{ white|dim=0.10 }}"
  }
}

# vim:ft=toml
