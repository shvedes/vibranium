#!/usr/bin/env bash

helpers::check VIBRANIUM_GLOBAL_SHOW_WALLPAPER
if [[ ! $VIBRANIUM_GLOBAL_SHOW_WALLPAPER == true ]]; then
  exit 0
fi

if ! systemctl -q --user is-active awww; then
  systemctl -q --user enable --now awww
fi

CURRENT_THEME="$(<"$XDG_CONFIG_HOME/vibranium/current/theme.name")"

if [[ ! -f "$VIBRANIUM_STATE/wallpaper/$CURRENT_THEME" ]]; then
  vb-core-wallpaper --get >"$VIBRANIUM_STATE/wallpaper/$CURRENT_THEME"
fi
