#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

# Try to restore prev cursor theme
prev_theme="$(<"$VIBRANIUM_STATE/cursor-theme")"
prev_size=$(<"$VIBRANIUM_STATE/cursor-size")

command rm -f "$VIBRANIUM_STATE/cursor-size"
command rm -f "$VIBRANIUM_STATE/cursor-theme"

vb-cursor-set "${prev_theme:-Adwaita}" --size ${prev_size:-24}

echo "${GREEN}[MIGRATION|$SELF]${RESET} Due to the change inside of the project's structure,"
echo "${GREEN}[MIGRATION|$SELF]${RESET} You may need to set your cursor theme again in"
echo "${GREEN}[MIGRATION|$SELF]${RESET} Vibranium Menu -> Settings > Misc"
