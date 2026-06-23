* {
  background-h:    {{ background|lightness=-0.10 }};
  background-0:    {{ background }};
  background-1:    {{ background|lightness=+0.05 }};
  background-2:    {{ background|lightness=+0.10 }};
  background-3:    {{ background|lightness=+0.15 }};
  background-4:    {{ background|lightness=+0.20 }};
  background-5:    {{ background|lightness=+0.25 }};

  foreground-h:    {{ foreground|lightness=+0.10 }};
  foreground-0:    {{ foreground }};
  foreground-1:    {{ foreground|lightness=-0.05 }};
  foreground-2:    {{ foreground|lightness=-0.10 }};
  foreground-3:    {{ foreground|lightness=-0.15 }};
  foreground-4:    {{ foreground|lightness=-0.20 }};

  black-dim:       {{ background|lightness=-0.10 }};
  black:           {{ background|lightness=-0.10 }};
  black-bright:    {{ background|lightness=+0.10 }};

  red-dim:         {{ color1|lightness=-0.10 }};
  red:             {{ color1 }};
  red-bright:      {{ color1|lightness=+0.10 }};

  pink-dim:        {{ color5|lightness=-0.10 }};
  pink:            {{ color5 }};
  pink-bright:     {{ color5|lightness=+0.10 }};

  green-dim:       {{ color2|lightness=-0.10 }};
  green:           {{ color2 }};
  green-bright:    {{ color2|lightness=+0.10 }};

  yellow-dim:      {{ color3|lightness=-0.10 }};
  yellow:          {{ color3 }};
  yellow-bright:   {{ color3|lightness=+0.10 }};

  orange-dim:      {{ color11|lightness=-0.10 }};
  orange:          {{ color11 }};
  orange-bright:   {{ color11|lightness=+0.10 }};

  blue-dim:        {{ color4|lightness=-0.10 }};
  blue:            {{ color4 }};
  blue-bright:     {{ color4|lightness=+0.10 }};

  purple-dim:      {{ color5|lightness=-0.10 }};
  purple:          {{ color5 }};
  purple-bright:   {{ color5|lightness=+0.10 }};

  cyan-dim:        {{ color6|lightness=-0.10 }};
  cyan:            {{ color6 }};
  cyan-bright:     {{ color6|lightness=+0.10 }};

  white-dim:       {{ foreground|lightness=-0.10 }};
  white:           {{ foreground }};
  white-bright:    {{ foreground|lightness=-0.10 }};

  gray-dim:        {{ background|lightness=+0.15 }};
  gray:            {{ background|lightness=+0.25 }};
  gray-bright:     {{ background|lightness=+0.35 }};

  accent-dim:      {{ accent|lightness=-0.10 }};
  accent:          {{ accent }};
  accent-bright:   {{ accent|lightness=+0.10 }};
}

/* vim: set ft=rasi: */
