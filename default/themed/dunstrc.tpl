[global]
format      = "<span foreground='{{ accent }}' size='10000'><b>%s</b></span>\n%b"
background  = "{{ background }}"
foreground  = "{{ foreground }}"
frame_color = "{{ color8 }}"
highlight   = "{{ color2 }}"

[urgency_low]
background  = "{{ background }}"
foreground  = "{{ foreground }}"
frame_color = "{{ color8 }}"
highlight   = "{{ accent }}"

[urgency_critical]
frame_color = "{{ color1 }}"
timeout = 0
