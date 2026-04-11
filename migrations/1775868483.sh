#!/usr/bin/env bash

mv ~/.local/share/icons/Vibranium ~/.local/share/icons/.Vibranium
cp -r $VIBRANIUM/extras/icons/Vibranium ~/.local/share/icons

APPS=(
  custom/vb-util-calculator
  org.pwmt.zathura
  thunar
  impala
  wiremix
  bluetui
  btop
  satty
  ncdu
  imv
)

for f in ${APPS[@]}; do
  cp "$VIBRANIUM/applications/${f}.desktop" ~/.local/share/applications/
done

cp -r $VIBRANIUM/applications/bluetui.desktop

gsettings set org.gnome.desktop.interface icon-theme 'Vibranium'
vb-theme-set-svg
