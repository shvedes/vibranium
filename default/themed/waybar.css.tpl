@define-color foreground     {{ foreground }};
@define-color background     {{ background }};

@define-color background-h   {{ background_lower|lightness=-0.10 }};
@define-color background-0   {{ background }};
@define-color background-1   {{ background_lower|lightness=+0.05 }};
@define-color background-2   {{ background_lower|lightness=+0.10 }};
@define-color background-3   {{ background_lower|lightness=+0.15 }};
@define-color background-4   {{ background_lower|lightness=+0.20 }};
@define-color background-5   {{ background_lower|lightness=+0.25 }};

@define-color foreground-h   {{ foreground_lower|lightness=+0.10 }};
@define-color foreground-0   {{ foreground }};
@define-color foreground-1   {{ foreground_lower|lightness=-0.05 }};
@define-color foreground-2   {{ foreground_lower|lightness=-0.10 }};
@define-color foreground-3   {{ foreground_lower|lightness=-0.15 }};
@define-color foreground-4   {{ foreground_lower|lightness=-0.20 }};

@define-color black-dim      {{ background_lower|lightness=-0.10 }};
@define-color black          {{ background_lower|lightness=-0.10 }};
@define-color black-br       {{ background_lower|lightness=+0.10 }};

@define-color red-dim        {{ color1|lightness=-0.10 }};
@define-color red            {{ color1 }};
@define-color red-br         {{ color1|lightness=+0.10 }};

@define-color pink-dim       {{ color5|lightness=-0.10 }};
@define-color pink           {{ color5 }};
@define-color pink-br        {{ color5|lightness=+0.10 }};

@define-color green-dim      {{ color2|lightness=-0.10 }};
@define-color green          {{ color2 }};
@define-color green-br       {{ color2|lightness=+0.10 }};

@define-color yellow-dim     {{ color3|lightness=-0.10 }};
@define-color yellow         {{ color3 }};
@define-color yellow-br      {{ color3|lightness=+0.10 }};

@define-color orange-dim     {{ color11|lightness=-0.10 }};
@define-color orange         {{ color11 }};
@define-color orange-br      {{ color11|lightness=+0.10 }};

@define-color blue-dim       {{ color4|lightness=-0.10 }};
@define-color blue           {{ color4 }};
@define-color blue-br        {{ color4|lightness=+0.10 }};

@define-color purple-dim     {{ color5|lightness=-0.10 }};
@define-color purple         {{ color5 }};
@define-color purple-br      {{ color5|lightness=+0.10 }};

@define-color cyan-dim       {{ color6|lightness=-0.10 }};
@define-color cyan           {{ color6 }};
@define-color cyan-br        {{ color6|lightness=+0.10 }};

@define-color white-dim      {{ foreground|lightness=-0.10 }};
@define-color white          {{ foreground }};
@define-color white-br       {{ foreground|lightness=-0.10 }};

@define-color gray-dim       {{ background|lightness=+0.15 }};
@define-color gray           {{ background|lightness=+0.25 }};
@define-color gray-br        {{ background|lightness=+0.35 }};

@define-color accent-dim     {{ accent|lightness=-0.10 }};
@define-color accent         {{ accent }};
@define-color accent-br      {{ accent|lightness=+0.10 }};

@define-color urgent         {{ color1 }};

/* vim: set ft=css: */
