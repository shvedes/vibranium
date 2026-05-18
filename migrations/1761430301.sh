#!/usr/bin/env bash

cfg="$HOME/.config/waybar/config.jsonc"

sed -i -e '/vibranium-update.jsonc",$/a\      "$XDG_DATA_HOME/vibranium/defaults/waybar/cpu.jsonc",\n\      "$XDG_DATA_HOME/vibranium/defaults/waybar/disk.jsonc",' \
	-e '/"hyprland\/language",$/a\      \/\/ "cpu",\n\      \/\/ "disk",' "$cfg"

systemctl --user restart waybar

echo "New waybar module: disk"
echo "New waybar module: cpu"
echo "To enable go to Vibranium settings > Configure Waybar > Enabled modules"
