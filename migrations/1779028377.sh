#!/bin/bash

sudo cp $VIBRANIUM/extras/usr/local/bin/patch-discord /usr/local/bin
sudo sed -i "s/user_placeholder/$USER/g" /usr/local/bin/patch-discord

if [[ -f /usr/bin/discord || -d "$HOME/.config/discord" ]]; then
  sudo bash /usr/local/bin/patch-discord
fi
