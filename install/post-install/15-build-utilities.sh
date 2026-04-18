#!/usr/bin/env bash

_log_info "Building Vibranium utilities"
_log_info "This might take a minute"

base_cwd="$(pwd)"
delete_rust=false

if ! command -v cargo >/dev/null; then
  delete_rust=true
  sudo pacman -S --noconfirm rust &>/dev/null
fi

git clone -q https://github.com/shvedes/hyprland-config-editor /tmp/hce && cd /tmp/hce

make install BINARY=vb-cmd-edit-wm-config PREFIX=~/.local/share/vibranium &>/dev/null

rm -rf /tmp/hce

if $delete_rust; then
  sudo pacman -Rnsc --noconfirm rust &>/dev/null
fi

cd "$base_cwd"
