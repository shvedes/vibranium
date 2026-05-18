#!/bin/bash

mkdir -p ~/.config/qt{5,6}ct/colors

for v in 5 6; do
  cfg="$HOME/.config/qt${v}ct/qt${v}ct.conf"
  theme="$HOME/.config/vibranium/current/theme/qtct.conf"
  theme_out=$HOME/.config/qt${v}ct/colors/Vibranium.conf

  ln -sf "$theme" ~/.config/qt${v}ct/colors/Vibranium.conf

  if grep -q '^custom_palette=' "$cfg"; then
    sed -i 's/^custom_palette=.*/custom_palette=true/' "$cfg"
  else
    sed -i "/^\[Appearance\]/a custom_palette=true" "$cfg"
  fi

  if grep -q '^color_scheme_path=' "$cfg"; then
    sed -i "s|^color_scheme_path=.*|color_scheme_path=$theme_out|" "$cfg"
  else
    sed -i "/^\[Appearance\]/a color_scheme_path=$theme_out" "$cfg"
  fi
done
