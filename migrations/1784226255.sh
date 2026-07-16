#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

bash "$VIBRANIUM/install/post-install/15-build-utilities.sh"
current="$(<"$XDG_CONFIG_HOME/vibranium/current/theme.name")"
vb-theme-set --force "$current"
