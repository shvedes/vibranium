#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

printf '#battery.warning, #battery.critical {\n\tcolor: @urgent;\n}' >>~/.config/waybar/style.css
