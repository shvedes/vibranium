#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

cp "$VIBRANIUM/config/vibranium/hooks/font-change.sh" "$XDG_CONFIG_HOME/vibranium/hooks"
