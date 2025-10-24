#!/usr/bin/env bash

cd "$VIBRANIUM"
cp ./config/systemd/user/vibranium-update.* "$HOME/.config/systemd/user"

systemctl --user daemon-reload
systemctl --user enable --now vibranium-update.timer
