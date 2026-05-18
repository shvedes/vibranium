#!/usr/bin/env bash

RESET=$'\e[0m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[0;33m'
N="$(basename "${0%.sh}")"

echo -e "${YELLOW}[MIGRATION $N]${RESET} Editing your waybar config file..."
sed -i 's/"position": .*,/\0\n\t\t"height": 30,/' \
	"$HOME/.config/waybar/config.jsonc"
echo -e  "${GREEN}[MIGRATION $N]${RESET} New feature: configurable Waybar height"
