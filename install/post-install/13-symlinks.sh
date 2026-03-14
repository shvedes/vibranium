#!/usr/bin/env bash

_log_info "Creating symlinks"

declare -A LINKS=(
  # It's probably not the best practice...
  ["$VIBRANIUM/default/uwsm/env"]="$HOME/.config/uwsm/env"

  ["$VIBRANIUM/applications/hidden"]="$HOME/.local/share/applications"
  ["$VIBRANIUM/applications/custom"]="$HOME/.local/share/applications"
)

for src in "${!LINKS[@]}"; do
  ln -sf "$src" "${LINKS[$src]}" > /dev/null
done

for src in "$VIBRANIUM"/applications/*.desktop; do
  ln -sf "$src" "$HOME/.local/share/applications/"
done

UpdateSummary "Configuration: symlinks for configuration files & custom .desktop entries"
