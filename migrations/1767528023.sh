#!/usr/bin/env bash

cp "$VIBRANIUM/config/systemd/user/alacritty.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now alacritty
