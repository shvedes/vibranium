#!/usr/bin/env bash

mkdir -p "$HOME/.config/systemd/user/hyprpaper.service.d"
echo -e "[Unit]\nStartLimitIntervalSec=0" \
    > "$HOME/.config/systemd/user/hyprpaper.service.d/override.conf"
systemctl --user daemon-reload

