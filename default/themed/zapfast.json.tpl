{
{{ #light }}
  "base": "light",
{{ #else }}
  "base": "dark",
{{ #end }}
  "colors": {
    "window": "{{ background }}",
    "panel": "{{ background|pop=0.06 }}",
    "surface": "{{ background|pop=0.12 }}",
    "surface_hover": "{{ background|pop=0.18 }}",
    "surface_active": "{{ background|pop=0.24 }}",
    "outline": "{{ background|pop=0.18 }}",
    "text": "{{ foreground }}",
    "secondary": "{{ foreground|dim=0.12 }}",
    "dim": "{{ foreground|dim=0.24 }}",
    "accent": "{{ accent }}",
    "accent_hover": "{{ accent|pop=0.12 }}",
    "on_accent": "{{ background }}",
    "danger": "{{ red }}",
    "warning": "{{ yellow }}",
    "overlay": "{{ background|pop=0.18 }}",
    "chat": "{{ background }}",
    "link": "{{ accent }}",
    "read": "{{ blue }}"
  }
}
