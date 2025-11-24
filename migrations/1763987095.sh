#!/usr/bin/env bash

sudo cp "$VIBRANIUM/extras/usr/local/bin/vibranium-bt-notify"      /usr/local/bin
sudo cp "$VIBRANIUM/extras/etc/udev/rules.d/99-vibranium-bt.rules" /etc/udev/rules.d
sudo udevadm control --reload
