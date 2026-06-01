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

  --color-pink-rgb: {{ color5_rgb|lightness=+0.10 }};
  --color-pink: {{ color5 }};

  --accent-h: {{ accent_h }};
  --accent-s: {{ accent_s }}%;
  --accent-l: {{ accent_l }}%;

  --text-normal: {{ foreground }};

  --link-external-color: var(--color-blue);
  --link-external-color-hover: var(--color-purple);

  --h1-color: inherit;
  --h2-color: inherit;
  --h3-color: inherit;
  --h4-color: inherit;
  --h5-color: inherit;
  --h6-color: inherit;

  /* Main document background, settings background */
  --color-base-00:  rgb({{ background_rgb }});

  --color-base-05:  rgb({{ background_rgb|lightness=+0.02 }});

  /* Code block color, options' island background */
  --color-base-10:  rgb({{ background_rgb|lightness=+0.04 }});

  /* Background of left & right section, context menu, canvas's drag icons background */
  --color-base-20:  rgb({{ background_rgb|lightness=+0.06 }});

  /* Input field background */
  --color-base-25:  rgb({{ background_rgb|lightness=-0.02 }});

  /* Top bar background, section border, canva's grid color
   * non accent-colored button background */
  --color-base-30:  rgb({{ background_rgb|lightness=+0.10 }});

   /* Background of inactive toggles, borders of some UI elements,
   * hover background on *some* buttons */
  --color-base-35:  rgb({{ background_rgb|lightness=+0.12 }});

  /* Mostly UI borders */
  --color-base-40:  rgb({{ background_rgb|lightness=+0.14 }});;

  /* Some UI elements color */
  --color-base-50:  rgb({{ background_rgb|lightness=+0.16 }});

  --color-base-60: rgb({{ foreground_rgb|lightness=-0.15 }});

  /* Text color in non-document places */
  --color-base-70: rgb({{ foreground_rgb|lightness=-0.10 }});

  /* Couldn't find it, but according to the default Obsidian theme,
   * this is equal to text color, as well as base-70 and base-60  */
  --color-base-100: rgb({{ foreground_rgb }});
}

/* Add barely visible border for settings sections */
/* It's a small change, but it makes a big difference visually */
.setting-group .setting-items {
  border: 1px solid rgb({{ background_rgb|lightness=+0.05 }});
}

.setting-group .setting-item {
  border-top: 1px solid rgb({{ background_rgb|lightness=+0.10 }});;
}

/* vim: set ft=css: */
