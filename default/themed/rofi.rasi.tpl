* {
  background:       rgb({{ background_rgb }});
  background-hard:  rgb({{ background_rgb|lightness=-0.3 }});

  foreground:       rgb({{ foreground_rgb }});
  foreground-muted: rgba({{ foreground_rgb }},0.4);

  border:    rgb({{ background_rgb|lightness=+0.15 }});
  selected:  rgb({{ background_rgb|lightness=+0.05 }});
  highlight: rgb({{ accent_rgb }});
}
