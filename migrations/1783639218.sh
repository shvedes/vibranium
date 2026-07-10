#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

if ! [[ $CHASSIS_TYPE =~ laptop|portable ]]; then
  exit 0
fi

sudo cp "$VIBRANIUM/extras/etc/udev/rules.d/10-power-profile.rules" /etc/udev/rules.d/
sudo udevadm control --reload
