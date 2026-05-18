#!/usr/bin/env bash

# Disable Discord's update checks
# https://wiki.archlinux.org/title/Discord#Discord_asks_for_an_update_not_yet_available_in_the_repository
mkdir -p "$HOME/.config/discord"
printf '{\n\t"SKIP_HOST_UPDATE": true\n}' > "$HOME/.config/discord/settings.json"
