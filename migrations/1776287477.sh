#!/usr/bin/env bash

sudo pacman -Rnsc --noconfirm engrampa &>/dev/null
vb-pkg-install --embedded -- xarchiver p7zip lrzip unarj unrar unzip zip
sed -i '/engrampa/d' ~/.config/mimeapps.list

cp /usr/share/applications/xarchiver.desktop ~/.local/share/applications
sed -i '/Name=/s/Name=.*/Name=Archive Manager/' ~/.local/share/applications/xarchiver.desktop

cp -r "$VIBRANIUM/config/xarchiver" ~/.config
