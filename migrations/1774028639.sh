#!/usr/bin/env bash

TIMESTAMP=$(date +'%s')

hyprctl -q keyword misc:disable_autoreload true

# Browser policies
CHROME_FOLDER="/etc/chromium/policies/managed"

sudo mkdir -p "$CHROME_FOLDER"
sudo chown -R "$USER:$USER" "$CHROME_FOLDER"

if command -v brave >/dev/null; then
  BRAVE_FOLDER="/etc/brave/policies/managed"
  sudo mkdir -p "$BRAVE_FOLDER"
  sudo chown -R "$USER:$USER" "$BRAVE_FOLDER"
fi

CURRENT_THEME="$(readlink "$XDG_CONFIG_HOME/vibranium/theme")"
CURRENT_THEME="$(basename "$CURRENT_THEME" 2>/dev/null || true)"
CURRENT_THEME="${CURRENT_THEME:-nightfox-nightfox}"

BACKUP_FOLDERS=(
  "vibranium"
  "alacritty"
  "swayosd"
  "waybar"
  "dunst"
  "nvim"
  "hypr"
  "imv"
)

nvim_found=false

# After — iterate bare names, apply prefix in the body
for folder in "${BACKUP_FOLDERS[@]}"; do
  if [[ $folder == nvim ]]; then
    nvim_found=true
  fi
  mv "$XDG_CONFIG_HOME/$folder" "$XDG_CONFIG_HOME/${folder}.${TIMESTAMP}"
done

for folder in "${BACKUP_FOLDERS[@]}"; do
  cp -r "$VIBRANIUM/config/$folder" "$XDG_CONFIG_HOME"
done

# Restore user overrides
mkdir -p "$XDG_CONFIG_HOME"/vibranium/{current,themes,themed,startup,shutdown}
cp "$XDG_CONFIG_HOME/vibrnaium.$TIMESTAMP"/{settings,environment} "$XDG_CONFIG_HOME/vibranium"/

cp "$XDG_CONFIG_HOME/hypr.$TIMESTAMP"/{hyprpaper,hyprsunset,hypridle,xdph}.conf $XDG_CONFIG_HOME/hypr
cp "$XDG_CONFIG_HOME/hypr.$TIMESTAMP/hyprland.conf.d"/* $XDG_CONFIG_HOME/hypr/hyprland.conf.d/
systemctl -q --user restart hyprsunset hypridle hyprpaper

rm -rf "$XDG_DATA_HOME/nvim"
rm -f "$HOME/.local/bin/imv-cheatsheet"
cp "$VIBRANIUM/extras/local/bin/imv-cheatsheet" "$HOME/.local/bin"

vb-theme-set "$CURRENT_THEME"

if [[ $nvim_found == true ]]; then
  echo "Your nvim configuration was moved to $XDG_CONFIG_HOME/nvim.$TIMESTAMP"
fi
ln -sf $XDG_CONFIG_HOME/vibranium/current/theme/neovim.lua $XDG_CONFIG_HOME/nvim/lua/plugins/theme.lua

(
  sleep 3
  systemctm -q --user restart alacritty
) &
