#!/usr/bin/env bash

cat << EOF > "$HOME/.config/hypr/xdph.conf"
screencopy {
    max_fps = 60
	allow_token_by_default = true
}
EOF
