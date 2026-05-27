#!/usr/bin/bash

mkdir -p \
  ~/.config/vibranium/themes/lush/backgrounds \
  ~/.config/vibranium/themes/lush-mono/backgrounds

curl -SsfL https://raw.githubusercontent.com/shvedes/vibranium-wallpapers/refs/heads/master/lush/backgrounds/01-lush-bg.jpg \
  --output ~/wall.jpg
mv ~/wall.jpg ~/.config/vibranium/themes/lush/backgrounds/01-lush-bg.jpg
ln -sf ~/.config/vibranium/themes/lush/backgrounds/01-lush-bg.jpg \
  ~/.config/vibranium/themes/lush-mono/backgrounds/01-lush-bg.jpg
