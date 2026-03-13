#!/usr/bin/env bash

FILES=(
  "$HOME/.config/hypr/hyprland.conf"
)

for f in "${FILES[@]}"; do
  chmod ug-w "$f"
done
