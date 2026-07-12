#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

sudo cp "$VIBRANIUM/extras/etc/pacman.d/hooks/80-discord.hook" /etc/pacman.d/hooks/
sudo cp "$VIBRANIUM/extras/etc/pacman.d/hooks/80-spotify.hook" /etc/pacman.d/hooks/
