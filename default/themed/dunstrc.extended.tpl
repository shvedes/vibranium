[global]
format      = "<span foreground='{{ accent }}' size='10000'><b>%s</b></span>\n%b"
background  = "{{ background_0 }}"
foreground  = "{{ foreground_0 }}"
frame_color = "{{ accent }}"
highlight   = "{{ accent }}"

[urgency_low]
background  = "{{ background_0 }}"
foreground  = "{{ foreground_0 }}"
frame_color = "{{ gray }}"
highlight   = "{{ gray }}"

[urgency_critical]
frame_color = "{{ red }}"
timeout = 0
