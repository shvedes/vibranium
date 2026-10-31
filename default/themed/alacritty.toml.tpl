colors = {
  primary = {
    background = "{{ background }}",
    foreground = "{{ foreground }}",
    dim_foreground = "{{ foreground|dim=0.24 }}",
    bright_foreground = "{{ foreground|pop=0.06 }}"
  },

  cursor = {
    text = "{{ background }}",
    cursor = "{{ foreground|dim=0.12 }}"
  },

  vi_mode_cursor = {
    text = "{{ foreground|pop=0.06 }}",
    cursor = "{{ blue }}"
  },

  search = {
    matches = {
      background = "{{ background|pop=0.12 }}",
      foreground = "{{ foreground }}"
    }
  },

  hints = {
    start = {
      background = "{{ background|pop=0.12 }}",
      foreground = "{{ foreground }}"
    },
    end = {
      background = "{{ background|pop=0.12 }}",
      foreground = "{{ foreground }}"
    }
  },

  line_indicator = {
    background = "{{ background|pop=0.12 }}",
    foreground = "{{ foreground }}"
  },

  footer_bar = {
    background = "{{ background|pop=0.12 }}",
    foreground = "{{ foreground }}"
  },

  selection = {
    background = "{{ background|pop=0.18 }}",
    foreground = "{{ foreground|pop=0.06 }}"
  },

  normal = {
    black   = "{{ background|pop=0.24 }}",
    red     = "{{ red }}",
    green   = "{{ green }}",
    yellow  = "{{ yellow }}",
    blue    = "{{ blue }}",
    magenta = "{{ purple }}",
    cyan    = "{{ cyan }}",
    white   = "{{ white }}"
  },

  bright = {
    black   = "{{ background|pop=0.30 }}",
    red     = "{{ red|pop=0.10 }}",
    green   = "{{ green|pop=0.10 }}",
    yellow  = "{{ yellow|pop=0.10 }}",
    blue    = "{{ blue|pop=0.10 }}",
    magenta = "{{ purple|pop=0.10 }}",
    cyan    = "{{ cyan|pop=0.10 }}",
    white   = "{{ white|pop=0.10 }}"
  },

  dim = {
    black   = "{{ background|pop=0.18 }}",
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
