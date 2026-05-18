#!/usr/bin/env bash

sed -i '/disk/d;/cpu/d' "$HOME/.config/waybar/config.jsonc"

awk '
/"modules-right"/ {in_list=1}
in_list && /"custom\/night-light"/ {next}
in_list && /"pulseaudio#volume"/ {
    print "\t\t\t\"custom/night-light\","
}
{print}
/]/ && in_list {in_list=0}
' "$HOME/.config/waybar/config.jsonc" \
	> "$HOME/.config/waybar/config.jsonc.tmp"
mv "$HOME/.config/waybar/config.jsonc.tmp" "$HOME/.config/waybar/config.jsonc"

systemctl --user restart waybar
