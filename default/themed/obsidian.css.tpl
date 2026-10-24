.theme-dark, .theme-light {

  --color-red-rgb: {{ red_rgb }};
  --color-red: {{ red }};

  --color-orange-rgb: {{ orange_rgb }};
  --color-orange: {{ orange }};

  --color-yellow-rgb: {{ yellow_rgb }};
  --color-yellow: {{ yellow }};

  --color-green-rgb: {{ green_rgb }};
  --color-green: {{ green }};

  --color-cyan-rgb: {{ cyan_rgb }};
  --color-cyan: {{ cyan }};

  --color-blue-rgb: {{ blue_rgb }};
  --color-blue: {{ blue }};

  --color-purple-rgb: {{ purple_rgb }};
  --color-purple: {{ purple }};

  --color-pink-rgb: {{ pink_rgb }};
  --color-pink: {{ pink }};

  --accent-h: {{ accent_h }};
  --accent-s: {{ accent_s }}%;
  --accent-l: {{ accent_l }}%;

  --text-normal: {{ foreground }};
  --link-external-color: {{ blue }};
  --link-external-color-hover: {{ purple }};

  --color-base-00:  {{ background }};
  --color-base-05:  {{ background }};
  --color-base-10:  {{ background|lightness=+0.03 }};
  --color-base-20:  {{ background|pop=0.06 }};
  --color-base-25:  {{ background|pop=0.12|lightness=-0.05 }};
  --color-base-30:  {{ background|pop=0.12|lightness=-0.05 }};
  --color-base-35:  {{ background|pop=0.18 }};
  --color-base-40:  {{ background|pop=0.18 }};
  --color-base-50:  {{ background|pop=0.30 }};
  --color-base-60:  {{ foreground|dim=0.12 }};
  --color-base-70:  {{ foreground|dim=0.06 }};
  --color-base-100: {{ foreground }};
}

/* Add barely visible border for settings sections */
/* It's a small change, but it makes a big difference visually */
.search-input-container input,
.setting-group .setting-items,
.setting-group .setting-group-search {
  border: 1px solid {{ background|pop=0.12 }};
}

.setting-group .setting-group-search {
  border-bottom: none;
}

/* vim: set ft=css: */
