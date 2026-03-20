#!/usr/bin/env bash

vb-pkg-install --embedded --no-verify --no-ask --force-install -- adw-gtk-theme papirus-icon-theme papirus-folders

rm -rf "$XDG_CONFIG_HOME"/qt?ct
cp -r "$VIBRANIUM"/config/qt?ct "$XDG_CONFIG_HOME"

if [[ "$(vb-theme-get)" =~ (dawm|latte|light)$ ]]; then
  gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3'
  gsettings set org.gnome.desktop.interface color-scheme 'default'
  gsettings set org.gnome.desktop.interface icon-theme "Papirus-Light"
  icon_theme="Papirus-Dark"
else
  gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark'
  gsettings set org.gnome.desktop.interface color-scheme 'default'
  gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
  icon_theme="Papirus-Light"
fi

sudo papirus-folders --color black --once --theme "$icon_theme" &> /dev/null
