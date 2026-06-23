#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

# Backup existing themes fodler in case if user had overrides.
mv "$XDG_CONFIG_HOME/rofi/themes" "$XDG_CONFIG_HOME/rofi/themes.bak"

# Copy the new, updated .rasi files.
cp -r "$VIBRANIUM/config/rofi/themes" "$XDG_CONFIG_HOME/rofi/themes"

# "Modern" is now called "Vibranium"
sed -i "s|\(@import \"./themes/\)[^\"]*|\1vibranium.rasi|" \
  "$XDG_CONFIG_HOME/rofi/config.rasi"

theme="$(<"$XDG_CONFIG_HOME/vibranium/current/theme.name")"
vb-theme-set --force "$theme"

echo "${GREEN}[MIGRATION|$SELF]${RESET} Existing rofi's themes/ folder has been backed up"
echo "${GREEN}[MIGRATION|$SELF]${RESET} Migrate manually if needed"
