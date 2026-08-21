set default-fg "{{ foreground_0 }}"
set default-bg "{{ background_0 }}"

set completion-bg "{{ background_1 }}"
set completion-fg "{{ foreground_h }}"

set completion-highlight-bg "rgba({{ accent_rgb }},0.3)"
set completion-highlight-fg "{{ foreground_h }}"

set completion-group-bg "{{ background_1 }}"
set completion-group-fg "{{ foreground_h }}"

set statusbar-fg "{{ foreground_0 }}"
set statusbar-bg "{{ background_1|lightness=+0.01 }}"

set notification-bg "{{ background_2 }}"
set notification-fg "{{ foreground_h }}"

set notification-error-bg "{{ red|dim=0.10 }}"
set notification-error-fg "{{ foreground_h }}"

set notification-warning-bg "{{ orange|dim=0.10 }}"
set notification-warning-fg "{{ foreground_h }}"

set inputbar-fg "{{ foreground_0 }}"
set inputbar-bg "{{ background_1 }}"

set recolor "true"
set recolor-lightcolor "{{ background_0 }}"
set recolor-darkcolor "{{ foreground_0 }}"

set index-fg "{{ accent|dim=0.10 }}"
set index-bg "{{ foreground_h }}"

set index-active-fg "{{ foreground_h }}"
set index-active-bg "{{ background_2 }}"

set render-loading-bg "{{ background_2 }}"
set render-loading-fg "{{ accent|pop=0.10 }}"

set highlight-color "rgba({{ accent_rgb }},0.5)"
set highlight-fg "{{ foreground_h }}"
set highlight-active-color "{{ accent|pop=0.10 }}"
