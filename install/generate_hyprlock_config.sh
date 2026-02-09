#!/usr/bin/env bash

cat << EOF > "$HOME/.config/hypr/hyprlock.conf"
source = ../vibranium/theme/current/hyprland.conf
source = ~/.local/share/vibranium/default/hypr/hyprlock.conf

background {
	# Auto generated. Do not edit!
	path = "$HOME/.config/vibranium/theme/current/backgrounds/01-nightfox-bg.jpg"
	color = \$background
    blur_size = 1
    blur_passes = 1
    brightness = 0.5
}

animations {
    enabled = true
}

# vim:ft=hyprlang
EOF
