#!/usr/bin/env bash

cat <<EOF > "$XDG_CONFIG_HOME/dunst/dunstrc"
[general]
font = "Cascadia Code 9"
origin = top-right
progress_bar_height = 15

# vim:ft=cfg
EOF
