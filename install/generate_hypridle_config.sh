#!/usr/bin/env bash

cat << EOF > "$HOME/.config/hypr/hypridle.conf"
source = ~/.local/share/vibranium/defaults/hypr/hypridle.conf

listener {
	# 10 minutes
	timeout = 600
	on-timeout = loginctl lock-session
}

listener {
	# 15 minutes
	timeout = 900
	on-timeout = systemctl suspend
}

# vim:ft=hyprlang
EOF
