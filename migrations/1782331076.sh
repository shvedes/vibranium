#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

if [[ "$CHASSIS_TYPE" =~ ^(vm|desktop)$ ]]; then
  exit 0
fi

echo "${GREEN}[MIGRATION|$SELF]${RESET} Some system files (/etc/udev/rules.d/) have been updated"
echo "${GREEN}[MIGRATION|$SELF]${RESET} To update them, you'll need sudo permissions:"

sudo cp $VIBRANIUM/extras/etc/udev/rules.d/99-vb-battery-alert.rules /etc/udev/rules.d/99-vb-battery-alert.rules
sudo sed -i "s/user_placeholder/$USER/g" /etc/udev/rules.d/99-vb-battery-alert.rules

sudo rm -f /etc/udev/rules.d/99-vb-ac.rules
sudo udevadm control --reload-rules
