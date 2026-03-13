#!/usr/bin/env bash

# Vibranium does not depend on the brightnessctl tool.
# It uses sysfs directly, so we need video group

# If the machine has backlight sysfs interface, add the user to the video group.
# It allows to manipulate '/sys/class/backlight' without sudo.
if [ ! -z "$(find /sys/class/backlight -mindepth 1 -maxdepth 1 2> /dev/null)" ]; then
  sudo usermod -aG video "$USER"
fi
