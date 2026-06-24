#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

echo "${GREEN}[MIGRATION|$SELF]${RESET} Some system files (/usr/local/bin/) have been updated"
echo "${GREEN}[MIGRATION|$SELF]${RESET} To update them, you'll need sudo permissions:"

sudo cp /usr/local/bin/patch-discord /usr/local/bin/patch-discord.$EPOCHSECONDS
sudo cp /usr/local/bin/patch-spotify /usr/local/bin/patch-spotify.$EPOCHSECONDS

sudo cp "$VIBRANIUM/extras/usr/local/bin/patch-discord" /usr/local/bin/
sudo cp "$VIBRANIUM/extras/usr/local/bin/patch-spotify" /usr/local/bin/
sudo cp "$VIBRANIUM/extras/etc/pacman.d/hooks/80-discord.hook" /etc/pacman.d/hooks/
