#!/usr/bin/env bash

set -euo pipefail

YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
RESET=$'\e[0m'

# Due to the active use of the papirus-folders script, 
# we need to keep the Papirus icon pack accessible for writing by regular users in order to avoid constant use of sudo.

CWD="$(pwd)"

printf "\n%s[VIBRANIUM]%s Installing icon theme" "${YELLOW}" "${RESET}"
cd ~/.cache
git clone -q https://github.com/PapirusDevelopmentTeam/papirus-icon-theme
cd papirus-icon-theme
mkdir -p "$HOME/.local/share/icons"
cp -r Papirus* "$HOME"/.local/share/icons

printf "\n%s[VIBRANIUM]%s Installing icon theme patcher" "${YELLOW}" "${RESET}"
mkdir -p "$HOME/.local/bin"
curl -s https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/refs/heads/master/install.sh \
	-o "$HOME/.local/bin/papirus-folders"
chmod +x "$HOME/.local/bin/papirus-folders"

rm -rf "$HOME"/.cache/papirus-icon-theme
cd "$CWD"
