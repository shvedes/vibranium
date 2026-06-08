#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

CURRENT="$(powerprofilesctl get)"

rm -f "$VIBRANIUM_STATE/power-profile"

vb-core-power $CURRENT

# Remove if needed.
echo "${GREEN}[MIGRATION|$SELF]${RESET} Message"
