#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'

SELF="${0##*/}"

mv ~/.config/hypr ~/.config/hypr.$EPOCHSECONDS

cp -r "$VIBRANIUM/config/hypr" ~/.config/

echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} ============================================================"
echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} == Hyprland now uses Lua-based configuration files        =="
echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} == Your old ~/.config/hypr has been backed up             =="
echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} == A new ~/.config/hypr has been created                  =="
echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} == Review the new config and adjust your settings         =="
echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} ============================================================"
