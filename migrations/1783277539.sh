#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

TARGET="$XDG_CONFIG_HOME/waybar/style.css"

awk '
{
    print

    if ($0 == "#battery.warning, #battery.critical {") {
        getline; print
        getline; print
        getline; print

        print ""
        print "#battery.charging, #battery.plugged {"
        print "  color: @green;"
        print "}"
    }
}
' "$TARGET" >"${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"

THEME="$(<"$XDG_CONFIG_HOME/vibranium/current/theme.name")"
vb-theme-set --force "$THEME"
