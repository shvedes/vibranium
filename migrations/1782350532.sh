#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

sed -i '/import/d' "$XDG_CONFIG_HOME/rofi/config.rasi"
printf '\n@import "./themes/vibranium.rasi"' >>"$XDG_CONFIG_HOME/rofi/config.rasi"
