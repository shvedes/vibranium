#!/usr/bin/env bash

cp "$VIBRANIUM/config/systemd/user/vibranium-startup.service" \
    "$HOME/.config/systemd/user/"

systemctl --user daemon-reload
systemctl --user --quiet enable vibranium-startup
