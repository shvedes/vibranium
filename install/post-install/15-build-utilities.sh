#!/bin/bash

helpers::log::info "Building Vibranium utilities"
helpers::log::info "This might take a minute"

base_cwd="$(pwd)"
delete_rust=false

if ! command -v cargo >/dev/null; then
  delete_rust=true
  sudo pacman -S --noconfirm rust &>/dev/null
fi

git clone -q https://github.com/shvedes/hyprland-config-editor --branch lua /tmp/hce && cd /tmp/hce

rm -f "$VIBRANIUM/bin/vb-cmd-edit-wm-config"
make install BINARY=vb-cmd-edit-wm-config PREFIX=~/.local/share/vibranium &>/dev/null

cd "$base_cwd"
rm -rf /tmp/hce

if $delete_rust; then
  sudo pacman -Rnsc --noconfirm rust &>/dev/null
fi
