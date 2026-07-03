#!/bin/bash

helpers::log::info "Setting up user groups"

# Specify the default groups to add the user to.
#
# I am aware that the "wheel" group can replace all of these,
# but if a specific application requires explicit device permissions,
# these groups can be useful.
GROUPS=(input audio video network storage)

# Vibranium does not depend on the brightnessctl tool.
# It accesses sysfs directly, so the user needs to be in the video group.
#
# If the machine has a backlight sysfs interface, add the user to the video group.
# This allows manipulating '/sys/class/backlight' without sudo.
if [[ ! -z "$(find /sys/class/backlight -mindepth 1 -maxdepth 1 2> /dev/null)" ]]; then
  GROUPS+=(video)
fi

GROUP_LIST=$(IFS=,; echo "${GROUPS[*]}")

sudo usermod -aG "$GROUP_LIST" "$USER"
