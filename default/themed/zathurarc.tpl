set default-fg "{{ foreground }}"
set default-bg "{{ background }}"

set completion-bg "{{ background|lightness=+0.07 }}"
set completion-fg "{{ foreground|lightness=+0.07 }}"
set completion-highlight-bg "{{ background|lightness=+0.20 }}"
set completion-highlight-fg "{{ foreground|lightness=+0.25 }}"
set completion-group-bg "{{ background|lightness=+0.10 }}"
set completion-group-fg "{{ foreground|lightness=+0.10 }}"

set statusbar-fg "{{ foreground|lightness=+0.07 }}"
set statusbar-bg "{{ background|lightness=+0.07 }}"

set notification-bg "{{ background|lightness=+0.07 }}"
set notification-fg "{{ foreground|lightness=+0.10 }}"
set notification-error-bg "{{ color1|lightness=-0.05 }}"
set notification-error-fg "{{ foreground|lightness=+0.15 }}"
set notification-warning-bg "{{ color3|lightness=-0.05 }}"
set notification-warning-fg "{{ color0 }}"

set inputbar-fg "{{ foreground|lightness=+0.05 }}"
set inputbar-bg "{{ background|lightness=+0.07 }}"

set recolor "true"
set recolor-lightcolor "{{ background }}"
set recolor-darkcolor "{{ foreground }}"

set index-fg "{{ background|lightness=+0.25 }}"
set index-bg "{{ background|lightness=+0.10 }}"
set index-active-fg "{{ foreground }}"
set index-active-bg "{{ selection_background }}"

set render-loading-bg "{{ background|lightness=+0.07 }}"
set render-loading-fg "{{ accent|lightness=+0.10 }}"

set highlight-color "rgba({{ background_rgb|lightness=+0.20 }},0.5)"
set highlight-fg "{{ foreground|lightness=+0.15 }}"
set highlight-active-color "{{ foreground|lightness=-0.05 }}"
