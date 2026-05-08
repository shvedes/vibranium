#!/bin/bash

cp "$VIBRANIUM"/config/hypr/hyprland.conf.d/event-* ~/.config/hypr/hyprland.conf.d/

notify-send -t 30000 "Vibranium - New Keybindings Were Added" '
To toggle a window group, press <b>SUPER + G</b>.
<b>See Vibranium Menu > Help > Keybindings for more information</b>'
