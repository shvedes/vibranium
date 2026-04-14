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

  /* --h1-color: inherit; */
  /* --h2-color: inherit; */
  /* --h3-color: inherit; */
  /* --h4-color: inherit; */
  /* --h5-color: inherit; */
  /* --h6-color: inherit; */

  /*
   *
   * Gradually build all base colors
   *
   */

  /* Main document background, settings background */
  --color-base-00:  {{ background_0 }};

  --color-base-05:  {{ background_0 }};

  /* Code block color, options' island background */
  --color-base-10:  {{ background_1 }};

  /* Background of  left & right section, context menu, canvas's drag icons background */
  --color-base-20:  rgba(calc({{ background_1_r }} * 0.8), calc({{ background_1_g }} * 0.8), calc({{ background_1_b }} * 0.8));

  /* Input field background */
  --color-base-25:  rgba(calc({{ background_0_r }} * 0.8), calc({{ background_0_g }} * 0.8), calc({{ background_0_b }} * 0.8));

  /* Top bar background, section border, canva's grid color
   * non accent-colored button background */
  --color-base-30:  {{ background_2 }};

   /* Background of inactive toggles, borders of some UI elements,
   * hover background on *some* buttons */
  --color-base-35:  {{ background_3 }};

  /* Mostly UI borders */
  --color-base-40:  {{ background_3 }};

  /* Some UI elements color */
  --color-base-50:  {{ background_5 }};

  --color-base-60: {{ foreground_2 }};

  /* Text color in non-document places */
  --color-base-70: {{ foreground_1 }};

  /* Couldn't find it, but according to the default Obsidian theme,
   * this is equal to text color, as well as base-70 and base-60  */
  --color-base-100: {{ foreground_0 }};
}

/* Add barely visible border for settings sections */
/* It's a small change, but it makes a big difference visually */
.setting-group .setting-items {
  border: 1px solid {{ background_3 }};
}

.setting-group .setting-item {
  border-top: 1px solid {{ background_2 }};
}

/* vim: set ft=css: */
