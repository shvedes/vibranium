#!/usr/bin/env bash

RESET=$'\e[0m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[0;33m'

export SUDO_PROMPT
SUDO_PROMPT="$(printf '%s[MIGRATION %s]%s Password for %s: ' "$YELLOW" "${0%.sh}" "$RESET" "$USER")"

echo -e "${YELLOW}[MIGRATION ${0%.sh}]${RESET} Applying new polkit rules"
sudo mkdir -p /etc/polkit-1/rules.d
sudo cp "$VIBRANIUM"/extras/etc/polkit-1/rules.d/50-vibranium-udisks2.rules \
	/etc/polkit-1/rules.d/
echo -e "${YELLOW}[MIGRATION ${0%.sh}]${RESET} Applying permissions"
sudo chmod 644 /etc/polkit-1/rules.d/50-vibranium-udisks2.rules

echo -e "${GREEN}[MIGRATION ${0%.sh}]${RESET} New feature: internal drives now mountable without sudo"
echo -e "${GREEN}[MIGRATION ${0%.sh}]${RESET} Note: no reboot required"
