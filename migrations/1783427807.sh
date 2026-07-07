#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

sed -i '/^#battery\.warning, #battery\.critical {/,/^}$/{
    /^}$/{
        n
        /^}$/d
    }
}' "$XDG_CONFIG_HOME/waybar/style.css"

echo "${GREEN}[MIGRATION|$SELF]${RESET} Fixed previous broken migration"
echo "${GREEN}[MIGRATION|$SELF]${RESET} My apologies"
