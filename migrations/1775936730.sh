#!/usr/bin/env bash

cp -r $VIBRANIUM/config/systemd/user/fetch-arch-updates.* ~/.config/systemd/user
systemctl -q --user daemon-reload

systemctl -q enable --now fetch-arch-updates.timer
