.theme-dark, .theme-light {

  --color-red-rgb: {{ color1_rgb }};
  --color-red: {{ color1 }};

  --color-orange-rgb: {{ color3_rgb }};
  --color-orange: {{ color3 }};

  --color-yellow-rgb: {{ color11_rgb }};
  --color-yellow: {{ color11 }};

  --color-green-rgb: {{ color2_rgb }};
  --color-green: {{ color2 }};

  --color-cyan-rgb: {{ color6_rgb }};
  --color-cyan: {{ color6 }};

  --color-blue-rgb: {{ color4_rgb }};
  --color-blue: {{ color4 }};

  --color-purple-rgb: {{ color5_rgb }};
  --color-purple: {{ color5 }};

  --color-pink-rgb: {{ color13_rgb }};
  --color-pink: {{ color13 }};

  --accent-h: {{ color4_h }};
  --accent-s: {{ color4_s }}%;
  --accent-l: {{ color4_l }}%;

  --text-normal: {{ color7 }};

  --link-external-color: {{ color4 }};
  --link-external-color-hover: {{ color5 }};

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
  --color-base-00:  {{ color0 }};

  --color-base-05:  {{ color0 }};

  /* Code block color, options' island background */
  --color-base-10:  {{ color0 }};

  /* Background of left & right section, context menu, canvas's drag icons background */
  --color-base-20:  rgba({{ color0_rgb }}, 0.8);

  /* Input field background */
  --color-base-25:  rgba({{ color0_rgb }}, 0.8);

  /* Top bar background, section border, canvas's grid color
   * non accent-colored button background */
  --color-base-30:  {{ color8 }};

   /* Background of inactive toggles, borders of some UI elements,
   * hover background on *some* buttons */
  --color-base-35:  {{ color8 }};

  /* Mostly UI borders */
  --color-base-40:  {{ color8 }};

  /* Some UI elements color */
  --color-base-50:  {{ color12 }};

  --color-base-60: {{ color6 }};

  /* Text color in non-document places */
  --color-base-70: {{ color7 }};

  /* Couldn't find it, but according to the default Obsidian theme,
   * this is equal to text color, as well as base-70 and base-60  */
  --color-base-100: {{ color7 }};
}

/* Add barely visible border for settings sections */
/* It's a small change, but it makes a big difference visually */
.setting-group .setting-items {
  border: 1px solid {{ color8 }};
}

.setting-group .setting-item {
  border-top: 1px solid {{ color8 }};
}

/* vim: set ft=css: */
