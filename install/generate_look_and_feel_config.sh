#!/usr/bin/env bash

cat << EOF > "$HOME/.config/hypr/hyprland.conf.d/look-and-feel.conf"
animations {
	enabled = true
}
decoration {
	dim_inactive = true

	blur {
		size = 5
	}
}

# vim:ft=hyprlang
EOF
