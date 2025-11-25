#!/usr/bin/env bash

CONFIG="$HOME/.config/waybar/config.jsonc"

awk '
/\$XDG_DATA_HOME\/vibranium\/defaults\/waybar\/recording-indicator\.jsonc/ {
    match($0, /^([ \t]+)/, m)
    indent = m[1]
    print indent "\"$XDG_DATA_HOME/vibranium/defaults/waybar/reading-mode.jsonc\","
}

/"custom\/recording-indicator"/ {
    match($0, /^([ \t]+)/, m)
    indent = m[1]
    print indent "\"custom/reading-mode\","
}

{ print }
' "$CONFIG" >  "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

systemctl --user restart waybar
