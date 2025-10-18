#!/usr/bin/env bash

rm -rf $HOME/.themes
rm -rf $HOME/.cache/{vibranium,hyprlock,papirus-icon-theme}
rm -rf $HOME/.local/bin
rm -rf $HOME/.local/state/vibranium
rm -rf $HOME/.local/share/{applications,themes,icons}
rm -rf $HOME/.config/{vibranium,uwsm,alacritty,btop,dunst,rofi,hypr,swayosd,wlogout,waybar,spicetify,gtk*,imv,qt6ct,systemd,zathura}

./install.sh
