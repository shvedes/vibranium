* {
  background-h:    {{ background_lower|lightness=-0.10 }};
  background-0:    {{ background }};
  background-1:    {{ background_lower|lightness=+0.05 }};
  background-2:    {{ background_lower|lightness=+0.10 }};
  background-3:    {{ background_lower|lightness=+0.15 }};
  background-4:    {{ background_lower|lightness=+0.20 }};
  background-5:    {{ background_lower|lightness=+0.25 }};

  foreground-h:    {{ foreground_lower|lightness=+0.10 }};
  foreground-0:    {{ foreground }};
  foreground-1:    {{ foreground_lower|lightness=-0.05 }};
  foreground-2:    {{ foreground_lower|lightness=-0.10 }};
  foreground-3:    {{ foreground_lower|lightness=-0.15 }};
  foreground-4:    {{ foreground_lower|lightness=-0.20 }};

  black-dim:       {{ background_lower|lightness=-0.10 }};
  black:           {{ background_lower|lightness=-0.10 }};
  black-bright:    {{ background_lower|lightness=+0.10 }};

  red-dim:         {{ color1_lower|lightness=-0.10 }};
  red:             {{ color1 }};
  red-bright:      {{ color1_lower|lightness=+0.10 }};

  pink-dim:        {{ color5_lower|lightness=-0.10 }};
  pink:            {{ color5 }};
  pink-bright:     {{ color5_lower|lightness=+0.10 }};

  green-dim:       {{ color2_lower|lightness=-0.10 }};
  green:           {{ color2 }};
  green-bright:    {{ color2_lower|lightness=+0.10 }};

  yellow-dim:      {{ color3_lower|lightness=-0.10 }};
  yellow:          {{ color3 }};
  yellow-bright:   {{ color3_lower|lightness=+0.10 }};

  orange-dim:      {{ color11_lower|lightness=-0.10 }};
  orange:          {{ color11 }};
  orange-bright:   {{ color11_lower|lightness=+0.10 }};

  blue-dim:        {{ color4_lower|lightness=-0.10 }};
  blue:            {{ color4 }};
  blue-bright:     {{ color4_lower|lightness=+0.10 }};

  purple-dim:      {{ color5_lower|lightness=-0.10 }};
  purple:          {{ color5 }};
  purple-bright:   {{ color5_lower|lightness=+0.10 }};

  cyan-dim:        {{ color6_lower|lightness=-0.10 }};
  cyan:            {{ color6 }};
  cyan-bright:     {{ color6_lower|lightness=+0.10 }};

  white-dim:       {{ foreground_lower|lightness=-0.10 }};
  white:           {{ foreground }};
  white-bright:    {{ foreground_lower|lightness=-0.10 }};

  gray-dim:        {{ background_lower|lightness=+0.15 }};
  gray:            {{ background_lower|lightness=+0.25 }};
  gray-bright:     {{ background_lower|lightness=+0.35 }};

  accent-dim:      {{ accent_lower|lightness=-0.10 }};
  accent:          {{ accent }};
  accent-bright:   {{ accent_lower|lightness=+0.10 }};
}

/* vim: set ft=rasi: */
