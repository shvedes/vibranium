#!/usr/bin/env bash

SETTINGS="$HOME/.config/vibranium/settings"

sudo pacman -Rnsc --noconfirm wlogout

if grep -q VIBRANIUM_GLOBAL_POWER_MENU_STYLE "$SETTINGS"; then
    sed -i '/VIBRANIUM_GLOBAL_POWER_MENU_STYLE/d' "$SETTINGS"
fi
