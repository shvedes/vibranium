#!/usr/bin/env bash

SERVICES=("waybar" "hyprpaper")

for unit in "${SERVICES[@]}"; do
	mkdir -p "$HOME/.config/systemd/user/${unit}.service.d"
    echo -e "[Unit]\nStartLimitIntervalSec=0" \
        > "$HOME/.config/systemd/user/${unit}.service.d/override.conf"
done

