#!/usr/bin/env bash

helpers::log::info "Creating symlinks"

declare -A LINKS=(
  # It's probably not the best practice...
  ["$VIBRANIUM/default/uwsm/env"]="$HOME/.config/uwsm/env"
  ["$HOME/.config/vibranium/current/theme/yazi.toml"]="$HOME/.config/yazi/theme.toml"
  ["$HOME/.config/vibranium/current/theme/hyprtoolkit.conf"]="$HOME/.config/hypr/hyprtoolkit.conf"
)

# Create required folders first
mkdir -p "$HOME"/.config/uwsm
mkdir -p "$HOME/.config/yazi"

for src in "${!LINKS[@]}"; do
  vb::symlink "$src" "${LINKS[$src]}"
done
