#!/usr/bin/env bash

cat << EOF > "$HOME/.config/hypr/hyprlock.conf"
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
