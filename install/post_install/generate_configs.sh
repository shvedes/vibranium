#!/usr/bin/env bash

mkdir -p "$XDG_CONFIG_HOME/spicetify/Themes/text"
mkdir -p "$XDG_CONFIG_HOME/alacritty"

cat << EOF > "$XDG_CONFIG_HOME/alacritty/alacritty.toml"
[general]
import = [ 
	"../../.local/share/vibranium/defaults/alacritty.toml",
	"../vibranium/theme/current/alacritty.toml"
]

[font.normal]
family = "Cascadia Code"
style  = "Regular"

[window]
opacity = 0.95
EOF

mkdir -p "$XDG_CONFIG_HOME/dunst"

cat <<EOF > "$XDG_CONFIG_HOME/dunst/dunstrc"
[general]
font = "Cascadia Code 9"
origin = top-right
progress_bar_height = 15

# vim:ft=cfg
EOF

