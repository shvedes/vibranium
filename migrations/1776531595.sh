#!/usr/bin/bash

sed -i 's/vb-cmd-toggle-inhibit/vb-toggle-inhibitor/' ~/.config/waybar/modules/custom-inhibitor.jsonc
sed -i 's/vb-cmd-toggle-output/vb-toggle-output/' ~/.config/waybar/modules/volume.jsonc
