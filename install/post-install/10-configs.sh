#!/usr/bin/env bash

_log_info "Copying configs"

mkdir -p \
  "$HOME"/.config/vibranium/{theme,startup,shutdown} \
  "$HOME"/.config/heroic/{themes,store} \
  "$HOME"/.config/hypr/hyprland.conf.d \
  "$HOME"/.local/share/applications \
  "$HOME"/.config/qt{5,6}ct/colors \
  "$HOME"/.local/state/vibranium \
  "$HOME"/.config/btop/themes \
  "$HOME"/.config/gtk-{3,4}.0 \
  "$HOME"/.config/discord \
  "$HOME"/.config/uwsm \
  "$HOME"/.local/bin

cp -r "$VIBRANIUM/config/"* "$HOME/.config/"
cp -r "$VIBRANIUM/extras/local/bin/"* "$HOME/.local/bin"
