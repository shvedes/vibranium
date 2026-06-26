#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

if ! vb-hw-battery; then
  exit 0
fi

echo "${GREEN}[MIGRATION|$SELF]${RESET} Registering your machine with the botnet network"
echo "${GREEN}[MIGRATION|$SELF]${RESET} Please enter your sudo password"
sudo cp "$VIBRANIUM/extras/etc/udev/rules.d/10-battery-alert.rules" \
  /etc/udev/rules.d/10-battery-alert.rules && sudo udevadm control --reload-rules
