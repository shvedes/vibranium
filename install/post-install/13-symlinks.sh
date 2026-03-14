#!/usr/bin/env bash

_log_info "Creating symlinks"

declare -A LINKS=(
  # It's probably not the best practice...
  ["$VIBRANIUM/default/uwsm/env"]="$HOME/.config/uwsm/env"
)

# Create required folders first
mkdir -p "$HOME"/.config/uwsm

for src in "${!LINKS[@]}"; do
  ln -sf "$src" "${LINKS[$src]}" > /dev/null
done

UpdateSummary "Configuration: symlinks for configuration files"
