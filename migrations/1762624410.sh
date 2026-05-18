#!/usr/bin/env bash

YELLOW=$'\e[0;33m'
RESET=$'\e[0m'
GREEN=$'\e[0;32m'

if [[ ! -z "$(ls -A /sys/class/backlight/)" ]]; then
    echo -e "${YELLOW}[VIBRANIUM]${RESET} Vibranium got rid of one more dependency and became even faster!"
    echo -e "${YELLOW}[VIBRANIUM]${RESET} Please enter your password to remove the dependency"
    sudo pacman -Rnsc brightnessctl --noconfirm

    if sudo usermod -aG video "$USER"; then
        echo -e "${GREEN}[VIBRANIUM]${RESET} You were added to a new group. Please restart your PC in order to be able to adjust your brightness again"
    fi
else
    # Desktop
    exit 0
fi
