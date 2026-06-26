[global]
format      = "<span foreground='{{ accent }}' size='10000'><b>%s</b></span>\n%b"
background  = "{{ background }}"
foreground  = "{{ foreground }}"
frame_color = "{{ accent|alpha=0.80 }}"
highlight   = "{{ accent|alpha=0.80 }}"

[urgency_low]
background  = "{{ background }}"
foreground  = "{{ foreground }}"
frame_color = "{{ background|lightness=+0.15 }}"
highlight   = "{{ background|lightness=+0.15 }}"

[urgency_critical]
frame_color = "{{ color1 }}"
timeout = 0
