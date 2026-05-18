#!/usr/bin/env bash

config="$HOME/.config/waybar/config.jsonc"

awk '
/"height"[[:space:]]*:/ {
    print
    match($0, /^[ \t]*/)
    indent = substr($0, RSTART, RLENGTH)
    print indent "\"spacing\": 0,"
    next
}
{ print }
' "$config" > "${config}.tmp" && mv "${config}.tmp" "$config"

