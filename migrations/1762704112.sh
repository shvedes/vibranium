#!/usr/bin/env bash

config="$HOME/.config/waybar/style.css"
start_pattern='^window#waybar[[:space:]]*\{'
end_pattern='^[[:space:]]*\}'

awk -v start_pat="$start_pattern" -v end_pat="$end_pattern" '
    BEGIN { in_block=0; found_bg=0; found_color=0 }
    {
        if ($0 ~ start_pat) in_block = 1
        if (in_block && $0 ~ /background-color[[:space:]]*:/) found_bg = 1
        if (in_block && $0 ~ /^[[:space:]]*color[[:space:]]*:/) found_color = 1

        if (in_block && $0 ~ end_pat) {
            if (!found_bg)  print "\t/* background-color: #000000; */"
            if (!found_color) print "\t/* color: #f1f1f1; */"
            in_block = 0
        }

        print
    }
' "$config" 2>/dev/null > "$config.tmp" && mv "$config.tmp" "$config"
