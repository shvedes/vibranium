set default-fg "{{ foreground }}"
set default-bg "{{ background }}"

set completion-bg "{{ background|pop=0.06 }}"
set completion-fg "{{ foreground|pop=0.06 }}"

set completion-highlight-bg "rgba({{ accent_rgb }},0.3)"
set completion-highlight-fg "{{ foreground|pop=0.06 }}"

set completion-group-bg "{{ background|pop=0.06 }}"
set completion-group-fg "{{ foreground|pop=0.06 }}"

set statusbar-fg "{{ foreground }}"
set statusbar-bg "{{ background|pop=0.06|lightness=+0.01 }}"

set notification-bg "{{ background|pop=0.12 }}"
set notification-fg "{{ foreground|pop=0.06 }}"

set notification-error-bg "{{ red|dim=0.10 }}"
set notification-error-fg "{{ foreground|pop=0.06 }}"

set notification-warning-bg "{{ orange|dim=0.10 }}"
set notification-warning-fg "{{ foreground|pop=0.06 }}"

set inputbar-fg "{{ foreground }}"
set inputbar-bg "{{ background|pop=0.06 }}"

set recolor "true"
set recolor-lightcolor "{{ background }}"
set recolor-darkcolor "{{ foreground }}"

set index-fg "{{ accent|dim=0.10 }}"
set index-bg "{{ foreground|pop=0.06 }}"

set index-active-fg "{{ foreground|pop=0.06 }}"
set index-active-bg "{{ background|pop=0.12 }}"

set render-loading-bg "{{ background|pop=0.12 }}"
set render-loading-fg "{{ accent|pop=0.10 }}"

set highlight-color "rgba({{ accent_rgb }},0.5)"
set highlight-fg "{{ foreground|pop=0.06 }}"
set highlight-active-color "{{ accent|pop=0.10 }}"
