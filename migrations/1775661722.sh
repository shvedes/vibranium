#!/usr/bin/env bash

TIMESTAMP=$(date +%s)

mv ~/.config/waybar ~/.config/waybar.$TIMESTAMP
cp -r $VIBRANIUM/config/waybar ~/.config

clean_rust=false

if ! command -v cargo >/dev/null; then
  clean_rust=true
  vb-pkg-install --embedded -- rust
fi

cd $VIBRANIUM/contrib/vb-cmd-edit-wm-config
bash build.sh

if [[ $clean_rust == true ]]; then
  sudo pacman -Rnsc --noconfirm rust &>/dev/null
fi
