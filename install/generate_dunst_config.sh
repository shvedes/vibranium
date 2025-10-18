#!/usr/bin/env bash

cat <<EOF > "$HOME/.config/dunst/dunstrc"
[general]
origin = top-right
font = "Cascadia Code 9"

corner_radius = 0
progress_bar_height = 15
progress_bar_corner_radius = 0

# vim:ft=cfg
EOF
