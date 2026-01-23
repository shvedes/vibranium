#!/usr/bin/env bash

cat << EOF > "$HOME/.config/hypr/hyprland.conf"
# Load current theme
source = ../vibranium/theme/current/hyprland.conf

# Load defaults
# NOTE: Under no circumstances should you delete these lines of code!
source = ~/.local/share/vibranium/default/hypr/autostart.conf
source = ~/.local/share/vibranium/default/hypr/general.conf
source = ~/.local/share/vibranium/default/hypr/layer-rules.conf
source = ~/.local/share/vibranium/default/hypr/look-and-feel.conf
source = ~/.local/share/vibranium/default/hypr/window-rules.conf
source = ~/.local/share/vibranium/default/hypr/persmissions.conf
source = ~/.local/share/vibranium/default/hypr/binds.conf
source = ~/.local/share/vibranium/default/hypr/input.conf

# Load user's overrides
source = ./hyprland.conf.d/*.conf
EOF
