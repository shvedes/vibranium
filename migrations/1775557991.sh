#!/usr/bin/env bash

TIMESTAMP="$(date +%s)"

vb-pkg-install --embedded -- app2unit xdg-terminal-exec

mv ~/.config/waybar ~/.config/waybar.$TIMESTAMP
cp -r $VIBRANIUM/config/waybar ~/.config/

mv ~/.config/Thunar/uca.xml ~/.config/Thunar/uca.xml.$TIMESTAMP
cp $VIBRANIUM/config/Thunar/uca.xml ~/.config/Thunar/

cp $VIBRANIUM/config/xdg-terminals.list ~/.config/

cp $VIBRANIUM/applications/hidden/{Alacritty,footclient}.desktop ~/.local/share/applications/
