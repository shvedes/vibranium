.theme-dark, .theme-light {

  --color-red-rgb: {{ color1_rgb }};
  --color-red: {{ color1 }};

  --color-orange-rgb: {{ color11_rgb }};
  --color-orange: {{ color11 }};

  --color-yellow-rgb: {{ color3_rgb }};
  --color-yellow: {{ color3 }};

  --color-green-rgb: {{ color2_rgb }};
  --color-green: {{ color2 }};

  --color-cyan-rgb: {{ color6_rgb }};
  --color-cyan: {{ color6 }};

  --color-blue-rgb: {{ color4_rgb }};
  --color-blue: {{ color4 }};

  --color-purple-rgb: {{ color5_rgb }};
  --color-purple: {{ color5 }};

  --color-pink-rgb: {{ color5_rgb }};
  --color-pink: {{ color5 }};

  --accent-h: {{ accent_h }};
  --accent-s: {{ accent_s }}%;
  --accent-l: {{ accent_l }}%;

  --text-normal: {{ foreground }};
  --link-external-color: var(--color-blue);
  --link-external-color-hover: var(--color-purple);

  --color-base-00:  {{ background }};
  --color-base-05:  {{ background }};
  --color-base-10:  {{ background|lightness=+0.03 }};
  --color-base-20:  {{ background|lightness=+0.02 }};
  --color-base-25:  {{ background|lightness=+0.05 }};
  --color-base-30:  {{ background|lightness=+0.10 }};
  --color-base-35:  {{ background|lightness=+0.13 }};
  --color-base-40:  {{ background|lightness=+0.15 }};
  --color-base-50:  {{ background|lightness=+0.25 }};
  --color-base-60:  {{ foreground|lightness=-0.10 }};
  --color-base-70:  {{ foreground|lightness=-0.05 }};
  --color-base-100: {{ foreground }};
}

/* Add barely visible border for settings sections */
/* It's a small change, but it makes a big difference visually */
.setting-group .setting-items,
.setting-group .setting-item,
.setting-group .setting-group-search {
  border: 1px solid {{ background|lightness=+0.15 }};
}

.setting-group .setting-group-search {
  border-bottom: none;
}

.setting-group .setting-item-heading {
  border: none;
}

/* vim: set ft=css: */
