#!/usr/bin/env bash

# Remove thunar's "Set as wallpaper" context menu. Keep Vibranium's one only
sudo rm /usr/lib/thunarx-3/thunar-wallpaper-plugin.so

# Also don't install the plugin when updating
sudo sed -i '/^#NoExtract/ s/^#//' /etc/pacman.conf
sudo sed -i '/^NoExtract/ s|$| usr/lib/thunarx-3/thunar-wallpaper-plugin.so|' /etc/pacman.conf

