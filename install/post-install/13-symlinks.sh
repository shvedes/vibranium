#!/bin/bash

helpers::log::info "Creating symlinks"

declare -A LINKS=(
  ["$VIBRANIUM/default/uwsm/env"]="$HOME/.config/uwsm/env"
  ["$HOME/.config/vibranium/current/theme/yazi.toml"]="$HOME/.config/yazi/theme.toml"
  ["$HOME/.config/vibranium/current/theme/hyprtoolkit.conf"]="$HOME/.config/hypr/hyprtoolkit.conf"
  ["$HOME/.config/zsh/.zshrc"]="$HOME/.zshrc"
)

mkdir -p \
  "$HOME/.config/uwsm" \
  "$HOME/.config/yazi"

for src in "${!LINKS[@]}"; do
  helpers::symlink "$src" "${LINKS[$src]}"
done
