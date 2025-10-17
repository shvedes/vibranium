#!/usr/bin/env bash

cat << EOF > "$HOME/.config/hypr/hyprlock.conf"
source = ../vibranium/theme/current/hyprland.conf
source = ~/.local/share/vibranium/defaults/hypr/hyprlock.conf

background {
	# Auto generated. Do not edit!
	path = "$HOME/.config/vibranium/theme/current/backgrounds/01-nightfox-bg.jpg"
	color = \$background
}

# vim:ft=hyprlang
EOF
