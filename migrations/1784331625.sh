#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

sudo cp "$VIBRANIUM"/extras/usr/local/bin/su-bridge     /usr/local/bin/su-bridge
sudo cp "$VIBRANIUM"/extras/etc/pacman.d/hooks/*.hook   /etc/pacman.d/hooks/

sudo cp "$VIBRANIUM"/extras/etc/udev/rules.d/80-android.rules /etc/udev/rules.d/
sudo cp "$VIBRANIUM"/extras/etc/udev/rules.d/80-usb-pen.rules /etc/udev/rules.d/

if [[ "$CHASSIS_TYPE" == "laptop" ]]; then
  sudo cp "$VIBRANIUM"/extras/etc/udev/rules.d/10-battery-alert.rules /etc/udev/rules.d/
  sudo cp "$VIBRANIUM"/extras/etc/udev/rules.d/10-power-profile.rules /etc/udev/rules.d/
fi

sudo cp "$VIBRANIUM"/extras/usr/share/polkit-1/actions/io.github.shvedes.vibranium.su-bridge /usr/share/polkit-1/actions
