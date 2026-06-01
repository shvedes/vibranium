#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"

bash $VIBRANIUM/install/post-install/31-vscode.sh

cp "$VIBRANIUM/config/vibranium/settings.advanced" ~/.config/vibranium
echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} New settings format has been added"
echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} Check out ~/.config/vibranium/settings.advanced"
