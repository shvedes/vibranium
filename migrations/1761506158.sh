#!/usr/bin/env bash

RESET=$'\e[0m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[0;33m'

export SUDO_PROMPT
SUDO_PROMPT="$(printf '%s[MIGRATION %s]%s Password for %s: ' "$YELLOW" "${0%.sh}" "$RESET" "$USER")"

GPU="$(lspci | grep -E "VGA compatible controller")"
if [[ "$GPU" =~ (UHD|Iris|Arc) ]]; then
	echo -e "${YELLOW}[MIGRATION ${0%.sh}]${RESET} Intel GPU detected. Installing new dependency: libva-intel-driver"
	sudo pacman -S --noconfirm libva-intel-driver
	echo -e "${GREEN}[MIGRATION ${0%.sh}]${RESET} Installation complete"
else
	echo -e "${GREEN}[MIGRATION ${0%.sh}]${RESET} Non-Intel GPU detected. Skipping installation"
fi
