* {
  background:       {{ background }};
  background-hard:  {{ background|lightness=-0.3 }};

  foreground:       rgb({{ foreground_rgb }});
  foreground-muted: rgb({{ background_rgb|lightness=+0.30 }});

  border:    {{ background|lightness=+0.15 }};
  selected:  {{ background|lightness=+0.07 }};
  highlight: {{ accent }};
}
