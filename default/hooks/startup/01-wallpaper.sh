#!/usr/bin/env bash

helpers::check VIBRANIUM_GLOBAL_SHOW_WALLPAPER
if [[ ! $VIBRANIUM_GLOBAL_SHOW_WALLPAPER == true ]]; then
  exit 0
fi

if ! systemctl -q --user is-active awww; then
  systemctl -q --user enable --now awww
fi

CURRENT_THEME="$(<"$XDG_CONFIG_HOME/vibranium/current/theme.name")"
WALLPAPER_REGISTRY="$VIBRANIUM_STATE/wallpapers"
WALLPAPER_PATH=""

while IFS='=' read -r key value; do
  if [[ $key == "$CURRENT_THEME" ]]; then
    WALLPAPER_PATH="${value#\"}"
    WALLPAPER_PATH="${WALLPAPER_PATH%\"}"
    break
  fi
done <"$WALLPAPER_REGISTRY"

if [[ -z $WALLPAPER_PATH ]]; then
  WALLPAPER_PATH="$(vb-core-wallpaper --get)"
  printf '%s="%s"\n' "$CURRENT_THEME" "$WALLPAPER_PATH" >>"$WALLPAPER_REGISTRY"
fi
