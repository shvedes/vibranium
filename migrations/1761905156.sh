#!/usr/bin/env bash

ln -sf "$VIBRANIUM/defaults/hypr/animations/default.conf" \
	"$HOME/.config/hypr/hyprland.conf.d/animations.conf"
hyprctl -q reload config-only
