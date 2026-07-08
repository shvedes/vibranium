#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

sudo cp "$VIBRANIUM/extras/etc/udev/rules.d/80-android.rules" /etc/udev/rules.d/80-usb-pen.rules
sudo udevadm control --reload
