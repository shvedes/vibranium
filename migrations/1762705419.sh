#!/usr/bin/env bash

sed -i 's|@import "~/.local/share/vibranium/defaults/rofi\.rasi"|@import "~/.local/share/vibranium/defaults/rofi-modern.rasi"|' "$HOME/.config/rofi/config.rasi"

