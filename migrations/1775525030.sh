#!/usr/bin/env bash

cp $VIBRANIUM/config/systemd/user/vibranium-inhibit@.service ~/.config/systemd/user
systemctl --user daemon-reload
