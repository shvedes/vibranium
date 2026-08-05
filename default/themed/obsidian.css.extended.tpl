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

  --text-normal: {{ foreground_0 }};
  --link-external-color: {{ blue }};
  --link-external-color-hover: {{ purple }};

  --color-base-00:  {{ background_0 }};
  --color-base-05:  {{ background_0 }};
  --color-base-10:  {{ background_1 }};
  --color-base-20:  {{ background_1 }};
  --color-base-25:  {{ background_2|lightness=-0.05 }};
  --color-base-30:  {{ background_2|lightness=-0.05 }};
  --color-base-35:  {{ background_3 }};
  --color-base-40:  {{ background_3 }};
  --color-base-50:  {{ background_5 }};
  --color-base-60:  {{ foreground_2 }};
  --color-base-70:  {{ foreground_1 }};
  --color-base-100: {{ foreground_0 }};
}

/* Add barely visible border for settings sections */
/* It's a small change, but it makes a big difference visually */
.setting-group .setting-items,
.setting-group .setting-group-search {
  border: 1px solid {{ background_3 }};
}

.setting-group .setting-group-search {
  border-bottom: none;
}

/* vim: set ft=css: */
