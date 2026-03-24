#!/bin/bash

mkdir -p ~/.config/qt{5,6}ct/colors

for v in 5 6; do
  ln -sf ~/.config/vibranium/current/theme/qtct.conf ~/.config/qt${v}ct/colors/Vibranium.conf
  sed -i '/custom_palette/s/=.*/true/' ~/.config/qt${v}ct/qt${v}ct.conf

  sed -i "s|^custom_palette=.*|custom_palette=/home/$USER/.config/vibranium/current/theme/qtct.conf|" \
    ~/.config/qt${v}ct/qt${v}ct.conf
done
