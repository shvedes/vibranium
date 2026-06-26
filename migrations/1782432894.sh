#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

mv ~/.config/rofi/themes/sleek.rasi ~/.config/rofi/themes/.sleek.rasi.$EPOCHSECONDS
mv ~/.config/rofi/themes/text.rasi ~/.config/rofi/themes/.text.rasi.$EPOCHSECONDS
mv ~/.config/rofi/themes/vibranium.rasi ~/.config/rofi/themes/vibranium.rasi.$EPOCHSECONDS

mv $VIBRANIUM/config/rofi/themes/sleek.rasi ~/.config/rofi/themes/
mv $VIBRANIUM/config/rofi/themes/text.rasi ~/.config/rofi/themes/
mv $VIBRANIUM/config/rofi/themes/vibranium.rasi ~/.config/rofi/themes/
