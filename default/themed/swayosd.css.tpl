@define-color text       {{ foreground }};
@define-color accent     {{ accent }};
@define-color border     {{ background|lightness=+0.15 }};
@define-color background {{ background }};

@define-color red        {{ color1 }};
@define-color red-br     {{ color1|lightness=+0.05 }};
@define-color red-dim    {{ color1|lightness=-0.05 }};

@define-color orange     {{ color11 }};
@define-color orange-br  {{ color11|lightness=+0.05 }};
@define-color orange-dim {{ color11|lightness=-0.05 }};

@define-color yellow     {{ color3 }};
@define-color yellow-br  {{ color3|lightness=+0.05 }};
@define-color yellow-dim {{ color3|lightness=-0.05 }};

@define-color green      {{ color2 }};
@define-color green-br   {{ color2|lightness=+0.05 }};
@define-color green-dim  {{ color2|lightness=-0.05 }};

@define-color cyan       {{ color6 }};
@define-color cyan-br    {{ color6|lightness=+0.05 }};
@define-color cyan-dim   {{ color6|lightness=-0.05 }};

@define-color urgent     {{ color1 }};

/* vim: set ft=css: */
