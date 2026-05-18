#!/usr/bin/env bash

file="$HOME/.config/waybar/config.jsonc"

awk '
     /"include": \[/ {
         print
         in_include = 1
         next
     }
     in_include && /\]/ {
         sub(/^[[:space:]]*\]/, "            \"$XDG_DATA_HOME/vibranium/defaults/waybar/cpu.jsonc\",\n            \"$XDG_DATA_HOME/vibranium/defaults/waybar/disk.jsonc\"\n        ]")
         in_include = 0
     }
     in_include && /vibranium-update\.jsonc"/ {
         if ($0 !~ /,/) sub(/"$/, "\",")
     }
     { print }
     ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
