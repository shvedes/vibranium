#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

mkdir -p "$HOME/.config/vibranium/user-menu.d"

if [[ ! -f "$HOME/.config/vibranium/user-menu.d/example.sh" ]]; then
  cp "$VIBRANIUM/config/vibranium/user-menu.d/example.sh" \
     "$HOME/.config/vibranium/user-menu.d/example.sh"
  echo "${GREEN}[MIGRATION|$SELF]${RESET} Created user-menu.d/example.sh"
fi
