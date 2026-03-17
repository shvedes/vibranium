#!/usr/bin/env bash

if [[ -f "$XDG_CONFIG_HOME/fish" ]]; then
  mv "$XDG_CONFIG_HOME/fish" "$XDG_CONFIG_HOME/fish.bak"
fi

cp -r $VIBRANIUM/config/fish ~/.config/fish
vb-pkg-install --embedded -- realtime-privileges fish
sudo usermod --append --groups wheel,audio,video,network,realtime $USER
