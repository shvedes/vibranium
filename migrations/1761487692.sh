#!/usr/bin/env bash

YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
RESET=$'\e[0m'
RED=$'\e[0;31m'

echo -e "${YELLOW}[MIGRATION]${RESET} Installing new dependency: ${YELLOW}ffmpegthumbnailer${RESET}"
if sudo pacman -S --noconfirm ffmpegthumbnailer &>/dev/null; then
	echo -e "${GREEN}[MIGRATION]${RESET} Migration complete"
else
	echo -e "${RED}[MIGRATION]${RESET} Failed to install ffmpegthumbnailer"
	exit 1
fi
